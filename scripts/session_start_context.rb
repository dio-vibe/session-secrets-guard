#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module SessionStartContext
  module_function

  def build_context(runtime)
    config = SessionSecrets.load_secret_config
    alias_count = config.aliases.length

    base = "This workspace enables secret guardrails. Raw credentials must never be echoed, stored in shell variables before use, " \
           "or fetched by hand from the backend — imported secrets are referenced via `#{SessionSecrets.placeholder_wrap('alias_name')}` placeholders only."

    runtime_note =
      if runtime == "claude"
        "To use a configured secret in a Bash command, put the literal `#{SessionSecrets.placeholder_wrap('alias_name')}` placeholder " \
        "directly in the command where the value belongs — for example: " \
        "`curl -H 'Authorization: Bearer #{SessionSecrets.placeholder_wrap('github_token')}' https://api.example.com`. " \
        "The PreToolUse hook will automatically rewrite that into a safe `run_with_secrets.sh` invocation before execution, " \
        "so the value never enters a shell variable, stdout, or the transcript. " \
        "DO NOT call `security find-generic-password`, `op read`, `vault read`, or `printenv <SECRET>` to fetch the value yourself. " \
        "DO NOT pipe a backend read into `echo`/`printf`. " \
        "DO NOT ask the user to paste the raw value again — imported secrets are already stored. " \
        "DO NOT substitute angle-bracket placeholders like `<token>` or example strings — emit the `#{SessionSecrets.placeholder_wrap('alias_name')}` exactly as configured."
      else
        "Codex cannot rewrite placeholders automatically. For commands that need a configured secret, " \
        "wrap them in `run_with_secrets.sh --set ENV_NAME=alias_spec -- your_command` so the value lands in the subprocess env rather than stdout. " \
        "DO NOT echo/printf the value or store it in a shell variable before piping into the consumer."
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
