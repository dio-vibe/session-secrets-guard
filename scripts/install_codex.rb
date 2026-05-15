#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "shellwords"

require_relative "common"

module InstallCodex
  REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
  EXAMPLE_CONFIG_PATH = REPO_ROOT.join("session-secrets.toml.example").freeze
  REPO_CONFIG_PATH = REPO_ROOT.join("session-secrets.toml").freeze
  MANAGED_SCRIPT_NAMES = %w[
    session_start_context.py
    session_start_context.rb
    user_prompt_submit_guard.py
    user_prompt_submit_guard.rb
    pre_tool_use_guard.py
    pre_tool_use_guard.rb
    post_tool_use_guard.py
    post_tool_use_guard.rb
    stop_session_scrub.py
    stop_session_scrub.rb
  ].freeze

  module_function

  def runtime_path
    Pathname.new(SessionSecrets.system_ruby_path)
  end

  def quoted_command(*parts)
    parts.flatten.compact.map { |part| Shellwords.escape(part.to_s) }.join(" ")
  end

  def build_hook_command(ruby_path, script_path, runtime, config_path = nil)
    parts = []
    if config_path
      parts.concat(["env", "SESSION_SECRETS_CONFIG=#{config_path}"])
    end
    parts.concat([ruby_path, script_path, "--runtime", runtime])
    quoted_command(parts)
  end

  def build_hooks_config(repo_root, ruby_path = runtime_path, config_path = nil)
    script_dir = Pathname.new(repo_root).join("scripts")
    {
      "hooks" => {
        "UserPromptSubmit" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => build_hook_command(
                  ruby_path,
                  script_dir.join("user_prompt_submit_guard.rb"),
                  "codex",
                  config_path
                ),
                "timeout" => 10,
                "statusMessage" => "Importing or validating secret refs"
              }
            ]
          }
        ],
        "PreToolUse" => [
          {
            "matcher" => "Bash|apply_patch|Edit|Write|mcp__.*",
            "hooks" => [
              {
                "type" => "command",
                "command" => build_hook_command(
                  ruby_path,
                  script_dir.join("pre_tool_use_guard.rb"),
                  "codex",
                  config_path
                ),
                "timeout" => 10,
                "statusMessage" => "Checking tool input for secrets"
              }
            ]
          }
        ],
        "PostToolUse" => [
          {
            "matcher" => "Bash|apply_patch|Edit|Write|mcp__.*",
            "hooks" => [
              {
                "type" => "command",
                "command" => build_hook_command(
                  ruby_path,
                  script_dir.join("post_tool_use_guard.rb"),
                  "codex",
                  config_path
                ),
                "timeout" => 10,
                "statusMessage" => "Checking tool output for secrets"
              }
            ]
          }
        ],
        "Stop" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => build_hook_command(
                  ruby_path,
                  script_dir.join("stop_session_scrub.rb"),
                  "codex",
                  config_path
                ),
                "timeout" => 10,
                "statusMessage" => "Scrubbing session history"
              }
            ]
          }
        ]
      }
    }
  end

  def ensure_session_config(repo_config_path = REPO_CONFIG_PATH, example_config_path = EXAMPLE_CONFIG_PATH)
    repo_config_path = Pathname.new(repo_config_path)
    example_config_path = Pathname.new(example_config_path)
    return false if repo_config_path.exist?

    repo_config_path.dirname.mkpath
    repo_config_path.write(example_config_path.read)
    true
  end

  def ensure_codex_hooks_enabled(config_text)
    section_pattern = /^(\[features\]\s*\n)(.*?)(?=^\[|\z)/m
    match = section_pattern.match(config_text)
    if match
      body = match[2]
      updated_body = body.gsub(/^codex_hooks\s*=.*$\n?/, "")
      if updated_body.match?(/^hooks\s*=/)
        updated_body = updated_body.sub(/^hooks\s*=.*$/, "hooks = true")
      else
        updated_body = "hooks = true\n#{updated_body}"
      end
      return config_text[0...match.begin(2)] + updated_body + config_text[match.end(2)..].to_s
    end

    normalized = config_text.rstrip
    normalized += "\n\n" unless normalized.empty?
    normalized + "[features]\nhooks = true\n"
  end

  def ensure_codex_config(config_path)
    config_path = Pathname.new(config_path)
    original = config_path.exist? ? config_path.read : ""
    updated = ensure_codex_hooks_enabled(original)
    return false if config_path.exist? && updated == original

    config_path.dirname.mkpath
    config_path.write(updated)
    true
  end

  def load_existing_hooks(hooks_path)
    hooks_path = Pathname.new(hooks_path)
    return { "hooks" => {} } unless hooks_path.exist?

    raw = JSON.parse(hooks_path.read)
    hooks = raw["hooks"]
    return raw if raw.is_a?(Hash) && hooks.is_a?(Hash)

    raise "Invalid hooks config at #{hooks_path}"
  end

  def merge_hooks(existing, desired)
    merged = { "hooks" => {} }
    existing_hooks = existing["hooks"].is_a?(Hash) ? existing["hooks"] : {}
    desired_hooks = desired["hooks"].is_a?(Hash) ? desired["hooks"] : {}

    (existing_hooks.keys | desired_hooks.keys).sort.each do |event_name|
      current_entries = existing_hooks[event_name].is_a?(Array) ? existing_hooks[event_name].dup : []
      desired_entries = desired_hooks[event_name].is_a?(Array) ? desired_hooks[event_name].dup : []
      current_entries = current_entries.reject { |entry| is_managed_hook_entry(entry) }
      desired_entries.each do |desired_entry|
        current_entries << desired_entry unless entry_exists(current_entries, desired_entry)
      end
      merged["hooks"][event_name] = current_entries
    end

    merged
  end

  def entry_exists(entries, desired_entry)
    desired_command = extract_first_command(desired_entry)
    return entries.include?(desired_entry) if desired_command.nil?

    entries.any? { |entry| extract_first_command(entry) == desired_command }
  end

  def extract_first_command(entry)
    return nil unless entry.is_a?(Hash)

    hooks = entry["hooks"]
    return nil unless hooks.is_a?(Array)

    hooks.each do |hook|
      next unless hook.is_a?(Hash)

      command = hook["command"]
      return command if command.is_a?(String)
    end
    nil
  end

  def is_managed_hook_entry(entry)
    command = extract_first_command(entry)
    return false if command.nil?

    MANAGED_SCRIPT_NAMES.any? { |script_name| command.include?(script_name) }
  end

  def ensure_hooks_json(hooks_path, repo_root, ruby_path = runtime_path, config_path = nil)
    desired = build_hooks_config(repo_root, ruby_path, config_path)
    existing = load_existing_hooks(hooks_path)
    merged = merge_hooks(existing, desired)
    rendered = JSON.pretty_generate(merged) + "\n"
    previous = Pathname.new(hooks_path).exist? ? Pathname.new(hooks_path).read : nil
    return false if previous == rendered

    hooks_path = Pathname.new(hooks_path)
    hooks_path.dirname.mkpath
    hooks_path.write(rendered)
    true
  end

  def write_hooks_json(hooks_path, repo_root, ruby_path = runtime_path, config_path = nil)
    ensure_hooks_json(hooks_path, repo_root, ruby_path, config_path)
  end

  def remove_managed_hooks(hooks_path)
    hooks_path = Pathname.new(hooks_path)
    return false unless hooks_path.exist?

    existing = load_existing_hooks(hooks_path)
    existing_hooks = existing["hooks"]
    raise "Invalid hooks config at #{hooks_path}" unless existing_hooks.is_a?(Hash)

    cleaned = { "hooks" => {} }
    changed = false

    existing_hooks.each do |event_name, entries|
      unless entries.is_a?(Array)
        cleaned["hooks"][event_name] = entries
        next
      end

      kept_entries = entries.reject { |entry| is_managed_hook_entry(entry) }
      changed = true if kept_entries.length != entries.length
      cleaned["hooks"][event_name] = kept_entries unless kept_entries.empty?
    end

    return false unless changed

    hooks_path.write(JSON.pretty_generate(cleaned) + "\n")
    true
  end

  def install(codex_home, repo_root = REPO_ROOT)
    codex_home = Pathname.new(codex_home).expand_path
    repo_root = Pathname.new(repo_root).expand_path
    repo_config_path = repo_root.join("session-secrets.toml")
    ruby_path = runtime_path

    {
      "config_created" => ensure_session_config(repo_config_path, repo_root.join("session-secrets.toml.example")),
      "codex_config_updated" => ensure_codex_config(codex_home.join("config.toml")),
      "hooks_updated" => ensure_hooks_json(codex_home.join("hooks.json"), repo_root, ruby_path, repo_config_path),
      "runtime_path" => ruby_path.to_s
    }
  end

  def parse_args(argv)
    options = {
      "repo_root" => REPO_ROOT.to_s,
      "codex_home" => Pathname.new(File.expand_path("~/.codex")).to_s
    }
    OptionParser.new do |parser|
      parser.on("--repo-root PATH") { |value| options["repo_root"] = value }
      parser.on("--codex-home PATH") { |value| options["codex_home"] = value }
    end.parse!(argv)
    options
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    repo_root = Pathname.new(File.expand_path(options["repo_root"]))
    codex_home = Pathname.new(File.expand_path(options["codex_home"]))
    results = install(codex_home, repo_root)

    puts "Session Secrets Guard installed for Codex."
    puts "- hooks:        #{codex_home.join('hooks.json')}"
    puts "- config:       #{repo_root.join('session-secrets.toml')}"
    puts "- codex config: #{codex_home.join('config.toml')}"
    puts "- runtime:      #{results['runtime_path']}"
    puts "- created config: #{results['config_created']}"
    puts "- updated hooks: #{results['hooks_updated']}"
    puts "- updated codex config: #{results['codex_config_updated']}"
    puts "Manual step: restart Codex, open /hooks, and review the 4 Session Secrets Guard hooks once."
    puts "This review step is a Codex security gate and is not auto-approved."
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(InstallCodex.main)
end
