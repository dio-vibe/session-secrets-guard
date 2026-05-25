#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

require_relative "common"

module PreToolUseGuard
  module_function

  def handle(payload, runtime)
    tool_name = payload["tool_name"]
    tool_input = payload["tool_input"]
    flattened_input = SessionSecrets.flatten_text(tool_input)
    config = SessionSecrets.load_secret_config
    refs = SessionSecrets.parse_inline_secret_refs(flattened_input, config)

    if !refs.empty? && tool_name != "Bash"
      return deny(
        "Inline secret references are only supported in Bash commands. Do not write secret placeholders into files, patches, or tool arguments."
      )
    end

    invalid_ref = refs.find { |ref| !ref.valid? }
    return deny(invalid_ref.error || "Invalid secret reference: #{invalid_ref.raw}") if invalid_ref

    secret_hits = SessionSecrets.find_secret_hits(flattened_input)
    unless secret_hits.empty?
      return deny(
        "Potential secret literal detected in tool input (#{SessionSecrets.summarize_hits(secret_hits)}). " \
        "Use env vars or a configured secret source instead of embedding raw values."
      )
    end

    return nil unless tool_name == "Bash"
    return nil unless tool_input.is_a?(Hash)

    command = tool_input["command"]
    return nil unless command.is_a?(String)

    unless refs.empty?
      if SessionSecrets.runtime_supports_input_rewrite(runtime)
        begin
          rewritten_command = SessionSecrets.build_secret_run_command(command, refs, config)
        rescue SessionSecrets::SecretResolutionError => e
          return deny(e.message)
        end

        updated_input = JSON.parse(JSON.generate(tool_input))
        updated_input["command"] = rewritten_command
        return {
          "hookSpecificOutput" => {
            "hookEventName" => "PreToolUse",
            "permissionDecision" => "allow",
            "updatedInput" => updated_input,
            "additionalContext" => "Rewrote inline secret placeholders into safe env injection for Bash: #{SessionSecrets.describe_inline_refs(refs)}."
          }
        }
      end

      return deny(
        "Codex cannot rewrite inline secret references in Bash input yet. Resolve each alias from its configured backend first, then rerun the command without the placeholder."
      )
    end

    unless SessionSecrets.is_secret_runner_command(command)
      bash_hits = SessionSecrets.find_sensitive_bash_hits(command)
      unless bash_hits.empty?
        guidance = build_sensitive_bash_guidance(bash_hits)
        return deny(
          "This Bash command looks like it would print or fetch secret material directly (#{SessionSecrets.summarize_hits(bash_hits)}). " \
          "Avoid printing raw secret material. #{guidance}"
        )
      end
    end

    nil
  end

  def build_sensitive_bash_guidance(hits)
    guidance = []
    if hits.include?("dump_secret_file")
      guidance << "For env or credential files, use the masking helper instead, for example: " \
                  "ruby scripts/mask_env_file.rb path/to/.env. " \
                  "For remote files, run an equivalent remote command that prints keys plus masked length/fingerprint, not values."
    end
    guidance << "If a command needs the value, resolve a configured alias from its backend and inject it as an env var."
    guidance.join(" ")
  end

  def deny(reason)
    {
      "systemMessage" => reason,
      "hookSpecificOutput" => {
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => reason
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
    response = handle(SessionSecrets.load_payload, parse_runtime(argv))
    SessionSecrets.emit_json(response) if response
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(PreToolUseGuard.main)
end
