#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"

require_relative "common"
require_relative "install_codex"
require_relative "install_codex_plugin"

module UninstallCodexPlugin
  module_function

  def remove_path(path)
    path = Pathname.new(path).expand_path
    return false unless path.exist?

    if path.directory? && !path.symlink?
      FileUtils.rm_rf(path.to_s)
    else
      path.delete
    end
    true
  end

  def remove_marketplace_plugin(marketplace_path, plugin_name)
    marketplace_path = Pathname.new(marketplace_path).expand_path
    return false unless marketplace_path.exist?

    raw = JSON.parse(marketplace_path.read)
    raise "Invalid marketplace file at #{marketplace_path}" unless raw.is_a?(Hash)
    plugins = raw["plugins"]
    return false unless plugins.is_a?(Array)

    filtered = plugins.reject { |plugin| plugin.is_a?(Hash) && plugin["name"] == plugin_name }
    return false if filtered.length == plugins.length

    raw["plugins"] = filtered
    marketplace_path.write(JSON.pretty_generate(raw) + "\n")
    true
  end

  def keychain_targets_from_config(config_path)
    config_path = Pathname.new(config_path).expand_path
    return [] unless config_path.exist?

    config = SessionSecrets.load_secret_config(config_path)
    targets = []
    config.aliases.each do |alias_name, alias_data|
      next unless alias_data["source"].to_s == "keychain"

      service = (alias_data["service"] || SessionSecrets.default_keychain_service(config)).to_s
      account = (alias_data["account"] || alias_name).to_s
      targets << [service, account]
    end
    targets.uniq.sort
  end

  def purge_keychain_entries(config_path)
    removed = 0
    missing = 0
    keychain_targets_from_config(config_path).each do |service, account|
      _stdout, stderr, status = Open3.capture3("security", "delete-generic-password", "-s", service, "-a", account)
      if status.success?
        removed += 1
        next
      end

      downcased = stderr.to_s.downcase
      if downcased.include?("could not be found") || downcased.include?("item could not be found")
        missing += 1
        next
      end

      raise "Failed to delete keychain entry service=#{service} account=#{account}: #{stderr}"
    end
    [removed, missing]
  end

  def uninstall_plugin(codex_home, marketplace_path, plugin_root, state_dir, purge_state:, purge_keychain:)
    codex_home = Pathname.new(codex_home).expand_path
    marketplace_path = Pathname.new(marketplace_path).expand_path
    plugin_root = Pathname.new(plugin_root).expand_path
    state_dir = Pathname.new(state_dir).expand_path
    config_path = state_dir.join("session-secrets.toml")

    removed_keychain = 0
    missing_keychain = 0
    if purge_keychain
      removed_keychain, missing_keychain = purge_keychain_entries(config_path)
    end

    {
      "plugin_removed" => remove_path(plugin_root),
      "cache_removed" => remove_path(codex_home.join("plugins", "cache", "personal-local", InstallCodexPlugin::DEFAULT_PLUGIN_NAME)),
      "marketplace_updated" => remove_marketplace_plugin(marketplace_path, InstallCodexPlugin::DEFAULT_PLUGIN_NAME),
      "global_hooks_updated" => InstallCodex.remove_managed_hooks(codex_home.join("hooks.json")),
      "state_removed" => purge_state ? remove_path(state_dir) : false,
      "keychain_removed" => removed_keychain,
      "keychain_missing" => missing_keychain,
      "state_preserved" => !purge_state
    }
  end

  def parse_args(argv)
    home = Pathname.new(File.expand_path("~"))
    options = {
      "codex_home" => home.join(".codex").to_s,
      "marketplace_path" => home.join(".agents", "plugins", "marketplace.json").to_s,
      "plugin_root" => home.join(".codex", "plugins", InstallCodexPlugin::DEFAULT_PLUGIN_NAME).to_s,
      "state_dir" => home.join(InstallCodexPlugin::DEFAULT_STATE_DIRNAME).to_s,
      "purge_state" => false,
      "purge_keychain" => false
    }
    OptionParser.new do |parser|
      parser.on("--codex-home PATH") { |value| options["codex_home"] = value }
      parser.on("--marketplace-path PATH") { |value| options["marketplace_path"] = value }
      parser.on("--plugin-root PATH") { |value| options["plugin_root"] = value }
      parser.on("--state-dir PATH") { |value| options["state_dir"] = value }
      parser.on("--purge-state") { options["purge_state"] = true }
      parser.on("--purge-keychain") { options["purge_keychain"] = true }
    end.parse!(argv)
    options
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    results = uninstall_plugin(
      options["codex_home"],
      options["marketplace_path"],
      options["plugin_root"],
      options["state_dir"],
      purge_state: options["purge_state"],
      purge_keychain: options["purge_keychain"]
    )

    puts "Session Secrets Guard uninstalled for Codex."
    puts "- removed staged plugin: #{results['plugin_removed']}"
    puts "- removed cache copy: #{results['cache_removed']}"
    puts "- updated marketplace: #{results['marketplace_updated']}"
    puts "- removed global hooks fallback: #{results['global_hooks_updated']}"
    puts "- removed state dir: #{results['state_removed']}"
    puts "- removed keychain entries: #{results['keychain_removed']}"
    puts "- missing keychain entries: #{results['keychain_missing']}"
    puts "Secret state was preserved. Use --purge-state to remove ~/.session-secrets-guard too." if results["state_preserved"]
    puts "Keychain secrets were preserved. Use --purge-keychain to delete stored items." unless options["purge_keychain"]
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(UninstallCodexPlugin.main)
end
