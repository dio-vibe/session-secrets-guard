#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

require_relative "install_codex"
require_relative "uninstall_codex_plugin"

module UninstallClaude
  DEFAULT_CLAUDE_HOME = Pathname.new(File.expand_path("~/.claude")).freeze
  DEFAULT_STATE_DIR = Pathname.new(File.expand_path("~/.session-secrets-guard-claude")).freeze

  module_function

  def remove_managed_claude_hooks(settings_path)
    settings_path = Pathname.new(settings_path).expand_path
    return false unless settings_path.exist?

    raw = JSON.parse(settings_path.read)
    raise "Invalid Claude settings file at #{settings_path}" unless raw.is_a?(Hash)
    existing_hooks = raw["hooks"]
    return false unless existing_hooks.is_a?(Hash)

    cleaned_hooks = {}
    changed = false
    existing_hooks.each do |event_name, entries|
      unless entries.is_a?(Array)
        cleaned_hooks[event_name] = entries
        next
      end

      kept_entries = entries.reject { |entry| InstallCodex.is_managed_hook_entry(entry) }
      changed = true if kept_entries.length != entries.length
      cleaned_hooks[event_name] = kept_entries unless kept_entries.empty?
    end
    return false unless changed

    rendered_obj = raw.dup
    if cleaned_hooks.empty?
      rendered_obj.delete("hooks")
    else
      rendered_obj["hooks"] = cleaned_hooks
    end

    settings_path.write(JSON.pretty_generate(rendered_obj) + "\n")
    true
  end

  def uninstall_claude(claude_home, state_dir, purge_state:, purge_keychain:)
    claude_home = Pathname.new(claude_home).expand_path
    state_dir = Pathname.new(state_dir).expand_path
    config_path = state_dir.join("session-secrets.toml")
    removed_keychain = 0
    missing_keychain = 0
    if purge_keychain
      removed_keychain, missing_keychain = UninstallCodexPlugin.purge_keychain_entries(config_path)
    end

    {
      "settings_updated" => remove_managed_claude_hooks(claude_home.join("settings.json")),
      "state_removed" => purge_state ? UninstallCodexPlugin.remove_path(state_dir) : false,
      "keychain_removed" => removed_keychain,
      "keychain_missing" => missing_keychain,
      "state_preserved" => !purge_state
    }
  end

  def parse_args(argv)
    options = {
      "claude_home" => DEFAULT_CLAUDE_HOME.to_s,
      "state_dir" => DEFAULT_STATE_DIR.to_s,
      "purge_state" => false,
      "purge_keychain" => false
    }
    OptionParser.new do |parser|
      parser.on("--claude-home PATH") { |value| options["claude_home"] = value }
      parser.on("--state-dir PATH") { |value| options["state_dir"] = value }
      parser.on("--purge-state") { options["purge_state"] = true }
      parser.on("--purge-keychain") { options["purge_keychain"] = true }
    end.parse!(argv)
    options
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    results = uninstall_claude(
      options["claude_home"],
      options["state_dir"],
      purge_state: options["purge_state"],
      purge_keychain: options["purge_keychain"]
    )

    puts "Session Secrets Guard uninstalled for Claude Code."
    puts "- updated settings: #{results['settings_updated']}"
    puts "- removed state dir: #{results['state_removed']}"
    puts "- removed keychain entries: #{results['keychain_removed']}"
    puts "- missing keychain entries: #{results['keychain_missing']}"
    puts "Secret state was preserved. Use --purge-state to remove ~/.session-secrets-guard-claude too." if results["state_preserved"]
    puts "Keychain secrets were preserved. Use --purge-keychain to delete stored items." unless options["purge_keychain"]
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(UninstallClaude.main)
end
