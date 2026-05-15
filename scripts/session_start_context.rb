#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module SessionStartContext
  module_function

  def build_context(runtime)
    config = SessionSecrets.load_secret_config
    alias_count = config.aliases.length

    base = "This workspace enables secret guardrails. Prefer local environment variables, `.env`, macOS Keychain, 1Password, Vault, or another approved secret source instead of pasting raw credentials. " \
           "Raw #{SessionSecrets.placeholder_wrap('secret')} placeholders can be imported into local storage and converted into reusable aliases."

    runtime_note =
      if runtime == "claude"
        "Bash commands that contain `#{SessionSecrets.placeholder_wrap('secret_ref')}` placeholders can be rewritten into safe env injection automatically by the hook. " \
        "When you need to resolve an alias manually, read it directly from its configured backend. Do not mention implementation details to the user unless asked."
      else
        "For Bash commands that need configured secrets, resolve the alias from its configured backend directly. " \
        "Use native reads such as `security find-generic-password` for Keychain-backed aliases or read the configured dotenv file for dotenv-backed aliases."
      end

    config_note =
      if config.path && config.path.exist?
        " Loaded secret aliases: #{alias_count} from #{config.path.basename}."
      else
        " No `session-secrets.toml` file is loaded yet; raw #{SessionSecrets.placeholder_wrap('secret')} imports can still create it automatically, and direct refs like " \
        "`#{SessionSecrets.placeholder_wrap('env:NAME')}`, `#{SessionSecrets.placeholder_wrap('dotenv:.env#NAME')}`, `#{SessionSecrets.placeholder_wrap('keychain:service/account')}`, " \
        "`#{SessionSecrets.placeholder_wrap('op:op://vault/item/field')}`, and `#{SessionSecrets.placeholder_wrap('vault:mount/path#field')}` still work."
      end

    "#{base} #{runtime_note}#{config_note} Never print, restate, commit, or patch raw secret values."
  end

  def handle(runtime)
    {
      "hookSpecificOutput" => {
        "hookEventName" => "SessionStart",
        "additionalContext" => build_context(runtime)
      }
    }
  end

  def parse_runtime(argv)
    runtime = "codex"
    OptionParser.new do |parser|
      parser.on("--runtime VALUE") { |value| runtime = value }
    end.parse!(argv)
    runtime
  end

  def main(argv = ARGV)
    runtime = parse_runtime(argv)
    SessionSecrets.load_payload
    SessionSecrets.emit_json(handle(runtime))
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(SessionStartContext.main)
end
