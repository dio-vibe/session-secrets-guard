#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

require_relative "install_codex"

module InstallClaude
  DEFAULT_CLAUDE_HOME = Pathname.new(File.expand_path("~/.claude")).freeze
  DEFAULT_STATE_DIR = Pathname.new(File.expand_path("~/.session-secrets-guard-claude")).freeze

  module_function

  def ensure_claude_state_defaults(config_path)
    config_path = Pathname.new(config_path)
    config = SessionSecrets.load_secret_config(config_path)
    defaults = SessionSecrets.deep_dup_hash(config.defaults)
    aliases = SessionSecrets.deep_dup_hash(config.aliases)

    return false if defaults["claude_prompt_import_mode"].to_s.strip.downcase == "block"

    defaults["claude_prompt_import_mode"] = "block"
    config_path.write(SessionSecrets.render_secret_config(defaults, aliases))
    true
  end

  def build_claude_hooks_config(repo_root, ruby_path, config_path)
    desired = InstallCodex.build_hooks_config(repo_root, ruby_path, config_path)
    hooks = JSON.parse(JSON.generate(desired["hooks"]))
    hooks.delete("Stop")

    pre_tool_use = hooks["PreToolUse"]
    if pre_tool_use.is_a?(Array) && pre_tool_use[0].is_a?(Hash)
      pre_tool_use[0]["matcher"] = "Bash|Edit|Write"
    end

    post_tool_use = hooks["PostToolUse"]
    if post_tool_use.is_a?(Array) && post_tool_use[0].is_a?(Hash)
      post_tool_use[0]["matcher"] = "Bash|Edit|Write"
    end

    hooks.each_value do |entries|
      next unless entries.is_a?(Array)

      entries.each do |entry|
        next unless entry.is_a?(Hash) && entry["hooks"].is_a?(Array)

        entry["hooks"].each do |hook|
          next unless hook.is_a?(Hash) && hook["command"].is_a?(String)

          hook["command"] = hook["command"].sub("--runtime codex", "--runtime claude")
        end
      end
    end

    {
      "$schema" => "https://json.schemastore.org/claude-code-settings.json",
      "hooks" => hooks
    }
  end

  def load_existing_settings(settings_path)
    settings_path = Pathname.new(settings_path)
    return { "$schema" => "https://json.schemastore.org/claude-code-settings.json" } unless settings_path.exist?

    raw = JSON.parse(settings_path.read)
    raise "Invalid Claude settings file at #{settings_path}" unless raw.is_a?(Hash)

    raw
  end

  def ensure_claude_settings(settings_path, repo_root, ruby_path, config_path)
    settings_path = Pathname.new(settings_path)
    desired = build_claude_hooks_config(repo_root, ruby_path, config_path)
    existing = load_existing_settings(settings_path)
    existing_hooks = existing["hooks"].is_a?(Hash) ? existing["hooks"] : {}
    merged_hooks = InstallCodex.merge_hooks({ "hooks" => existing_hooks }, desired)["hooks"]

    rendered_obj = existing.merge(
      "$schema" => "https://json.schemastore.org/claude-code-settings.json",
      "hooks" => merged_hooks
    )
    rendered = JSON.pretty_generate(rendered_obj) + "\n"
    previous = settings_path.exist? ? settings_path.read : nil
    return false if previous == rendered

    settings_path.dirname.mkpath
    settings_path.write(rendered)
    true
  end

  def install_claude(repo_root, claude_home, state_dir)
    repo_root = Pathname.new(repo_root).expand_path
    claude_home = Pathname.new(claude_home).expand_path
    state_dir = Pathname.new(state_dir).expand_path

    config_path = state_dir.join("session-secrets.toml")
    state_dir.mkpath
    state_created = InstallCodex.ensure_session_config(config_path, repo_root.join("session-secrets.toml.example"))
    state_defaults_updated = ensure_claude_state_defaults(config_path)
    ruby_path = InstallCodex.runtime_path
    settings_updated = ensure_claude_settings(claude_home.join("settings.json"), repo_root, ruby_path, config_path)
    {
      "state_config_created" => state_created,
      "state_defaults_updated" => state_defaults_updated,
      "runtime_path" => ruby_path.to_s,
      "settings_updated" => settings_updated
    }
  end

  def parse_args(argv)
    options = {
      "repo_root" => InstallCodex::REPO_ROOT.to_s,
      "claude_home" => DEFAULT_CLAUDE_HOME.to_s,
      "state_dir" => DEFAULT_STATE_DIR.to_s
    }
    OptionParser.new do |parser|
      parser.on("--repo-root PATH") { |value| options["repo_root"] = value }
      parser.on("--claude-home PATH") { |value| options["claude_home"] = value }
      parser.on("--state-dir PATH") { |value| options["state_dir"] = value }
    end.parse!(argv)
    options
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    results = install_claude(options["repo_root"], options["claude_home"], options["state_dir"])

    puts "Session Secrets Guard installed for Claude Code."
    puts "- settings:      #{Pathname.new(options['claude_home']).join('settings.json')}"
    puts "- state config:  #{Pathname.new(options['state_dir']).join('session-secrets.toml')}"
    puts "- runtime:       #{results['runtime_path']}"
    puts "- created state config: #{results['state_config_created']}"
    puts "- updated Claude defaults: #{results['state_defaults_updated']}"
    puts "- updated settings: #{results['settings_updated']}"
    puts "Restart Claude Code to pick up the updated hooks."
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(InstallClaude.main)
end
