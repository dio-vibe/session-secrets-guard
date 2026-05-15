#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "open3"
require "optparse"
require "pathname"

require_relative "common"
require_relative "install_codex"

module InstallCodexPlugin
  DEFAULT_PLUGIN_NAME = "session-secrets-guard"
  DEFAULT_MARKETPLACE_NAME = "personal-local"
  DEFAULT_MARKETPLACE_DISPLAY_NAME = "Personal Plugins"
  DEFAULT_STATE_DIRNAME = ".session-secrets-guard"
  IGNORE_NAMES = %w[
    .DS_Store
    .git
    .pytest_cache
    __pycache__
    hook_outputs
    session-secrets.toml
  ].freeze

  module_function

  def plugin_manifest_path(plugin_root)
    Pathname.new(plugin_root).join(".codex-plugin", "plugin.json")
  end

  def ignored_name?(name)
    IGNORE_NAMES.include?(name) || name.end_with?(".pyc")
  end

  def stage_plugin(source_root, plugin_root)
    source_root = Pathname.new(source_root).expand_path
    plugin_root = Pathname.new(plugin_root).expand_path
    return false if source_root == plugin_root

    FileUtils.rm_rf(plugin_root.to_s) if plugin_root.exist?
    plugin_root.dirname.mkpath

    Find.find(source_root.to_s) do |source|
      source_path = Pathname.new(source)
      relative = source_path.relative_path_from(source_root)
      next if relative.to_s == "."

      name = source_path.basename.to_s
      if ignored_name?(name)
        Find.prune if source_path.directory?
        next
      end

      destination = plugin_root.join(relative)
      if source_path.directory?
        destination.mkpath
      else
        destination.dirname.mkpath
        FileUtils.copy_file(source_path.to_s, destination.to_s, preserve: true)
      end
    end
    true
  end

  def ensure_state_config(state_dir, example_config_path)
    state_dir = Pathname.new(state_dir).expand_path
    state_dir.mkpath
    config_path = state_dir.join("session-secrets.toml")
    created = InstallCodex.ensure_session_config(config_path, example_config_path)
    [config_path, created]
  end

  def marketplace_root_for_path(marketplace_path)
    marketplace_path = Pathname.new(marketplace_path).expand_path
    raise "Cannot determine marketplace root for #{marketplace_path}" if marketplace_path.each_filename.count < 4

    marketplace_path.parent.parent.parent
  end

  def relative_marketplace_path(marketplace_path, plugin_root)
    root = marketplace_root_for_path(marketplace_path)
    relative = Pathname.new(plugin_root).expand_path.relative_path_from(root)
    "./#{relative.to_s.tr(File::SEPARATOR, '/')}"
  end

  def load_marketplace(marketplace_path)
    marketplace_path = Pathname.new(marketplace_path)
    unless marketplace_path.exist?
      return {
        "name" => DEFAULT_MARKETPLACE_NAME,
        "interface" => { "displayName" => DEFAULT_MARKETPLACE_DISPLAY_NAME },
        "plugins" => []
      }
    end

    raw = JSON.parse(marketplace_path.read)
    raise "Invalid marketplace file at #{marketplace_path}" unless raw.is_a?(Hash)

    raw["plugins"] = [] unless raw["plugins"].is_a?(Array)
    raw["name"] ||= DEFAULT_MARKETPLACE_NAME
    raw["interface"] = { "displayName" => DEFAULT_MARKETPLACE_DISPLAY_NAME } unless raw["interface"].is_a?(Hash)
    raw
  end

  def ensure_marketplace_plugin(marketplace_path, plugin_name, plugin_root, category)
    marketplace_path = Pathname.new(marketplace_path)
    marketplace = load_marketplace(marketplace_path)
    plugins = marketplace["plugins"]
    path_value = relative_marketplace_path(marketplace_path, plugin_root)
    entry = {
      "name" => plugin_name,
      "source" => {
        "source" => "local",
        "path" => path_value
      },
      "policy" => {
        "installation" => "AVAILABLE",
        "authentication" => "ON_INSTALL"
      },
      "category" => category
    }

    replaced = false
    plugins.each_with_index do |existing, index|
      next unless existing.is_a?(Hash) && existing["name"] == plugin_name

      if existing == entry
        replaced = true
        break
      end
      plugins[index] = entry
      replaced = true
      break
    end
    plugins << entry unless replaced

    rendered = JSON.pretty_generate(marketplace) + "\n"
    previous = marketplace_path.exist? ? marketplace_path.read : nil
    return false if previous == rendered

    marketplace_path.dirname.mkpath
    marketplace_path.write(rendered)
    true
  end

  def load_plugin_metadata(plugin_root)
    raw = JSON.parse(plugin_manifest_path(plugin_root).read)
    raise "Invalid plugin manifest at #{plugin_manifest_path(plugin_root)}" unless raw.is_a?(Hash)

    plugin_name = (raw["name"] || DEFAULT_PLUGIN_NAME).to_s
    interface = raw["interface"]
    category = interface.is_a?(Hash) && interface["category"] ? interface["category"].to_s : "Productivity"
    [plugin_name, category]
  end

  def get_codex_feature_enabled(feature_name)
    codex_binary = SessionSecrets.find_executable("codex")
    return nil if codex_binary.nil?

    stdout, _stderr, status = Open3.capture3(codex_binary, "features", "list")
    return nil unless status.success?

    stdout.each_line do |line|
      columns = line.split
      next unless columns.length >= 3 && columns[0] == feature_name

      return columns[-1].downcase == "true"
    end
    nil
  rescue StandardError
    nil
  end

  def install_plugin(source_root, codex_home, marketplace_path, plugin_root, state_dir)
    source_root = Pathname.new(source_root).expand_path
    codex_home = Pathname.new(codex_home).expand_path
    marketplace_path = Pathname.new(marketplace_path).expand_path
    plugin_root = Pathname.new(plugin_root).expand_path
    state_dir = Pathname.new(state_dir).expand_path

    staged = stage_plugin(source_root, plugin_root)
    config_path, state_created = ensure_state_config(state_dir, source_root.join("session-secrets.toml.example"))
    ruby_path = InstallCodex.runtime_path
    hooks_updated = InstallCodex.write_hooks_json(plugin_root.join("hooks", "hooks.json"), plugin_root, ruby_path, config_path)
    codex_config_updated = InstallCodex.ensure_codex_config(codex_home.join("config.toml"))
    plugin_hooks_enabled = get_codex_feature_enabled("plugin_hooks")
    global_hooks_updated = false
    global_hooks_updated = InstallCodex.ensure_hooks_json(codex_home.join("hooks.json"), plugin_root, ruby_path, config_path) unless plugin_hooks_enabled == true
    plugin_name, category = load_plugin_metadata(plugin_root)
    marketplace_updated = ensure_marketplace_plugin(marketplace_path, plugin_name, plugin_root, category)

    {
      "plugin_staged" => staged,
      "state_config_created" => state_created,
      "runtime_path" => ruby_path.to_s,
      "plugin_hooks_updated" => hooks_updated,
      "global_hooks_updated" => global_hooks_updated,
      "codex_config_updated" => codex_config_updated,
      "marketplace_updated" => marketplace_updated,
      "plugin_hooks_enabled" => plugin_hooks_enabled == true
    }
  end

  def parse_args(argv)
    home = Pathname.new(File.expand_path("~"))
    options = {
      "source_root" => InstallCodex::REPO_ROOT.to_s,
      "codex_home" => home.join(".codex").to_s,
      "marketplace_path" => home.join(".agents", "plugins", "marketplace.json").to_s,
      "plugin_root" => home.join(".codex", "plugins", DEFAULT_PLUGIN_NAME).to_s,
      "state_dir" => home.join(DEFAULT_STATE_DIRNAME).to_s
    }
    OptionParser.new do |parser|
      parser.on("--source-root PATH") { |value| options["source_root"] = value }
      parser.on("--codex-home PATH") { |value| options["codex_home"] = value }
      parser.on("--marketplace-path PATH") { |value| options["marketplace_path"] = value }
      parser.on("--plugin-root PATH") { |value| options["plugin_root"] = value }
      parser.on("--state-dir PATH") { |value| options["state_dir"] = value }
    end.parse!(argv)
    options
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    results = install_plugin(
      options["source_root"],
      options["codex_home"],
      options["marketplace_path"],
      options["plugin_root"],
      options["state_dir"]
    )

    puts "Codex marketplace plugin staged."
    puts "- staged plugin: #{options['plugin_root']}"
    puts "- state config:  #{Pathname.new(options['state_dir']).join('session-secrets.toml')}"
    puts "- marketplace:   #{options['marketplace_path']}"
    puts "- codex config:  #{Pathname.new(options['codex_home']).join('config.toml')}"
    puts "- runtime:       #{results['runtime_path']}"
    puts "- staged plugin copy: #{results['plugin_staged']}"
    puts "- created state config: #{results['state_config_created']}"
    puts "- updated plugin hooks bundle: #{results['plugin_hooks_updated']}"
    puts "- updated global hooks fallback: #{results['global_hooks_updated']}"
    puts "- updated codex config: #{results['codex_config_updated']}"
    puts "- updated marketplace: #{results['marketplace_updated']}"
    if results["plugin_hooks_enabled"]
      puts "Restart Codex and enable Session Secrets Guard from Personal Plugins."
    else
      puts "Current Codex build does not load plugin-bundled hooks yet."
      puts "The installer also wrote ~/.codex/hooks.json as the active fallback."
    end
    puts "Manual step: restart Codex, open /hooks, and review the 4 Session Secrets Guard hooks once."
    puts "This review step is a Codex security gate and is not auto-approved."
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(InstallCodexPlugin.main)
end
