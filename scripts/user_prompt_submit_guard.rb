#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module UserPromptSubmitGuard
  module_function

  def handle(payload, runtime)
    prompt = payload["prompt"]
    return nil unless prompt.is_a?(String)

    config = SessionSecrets.load_secret_config
    raw_imports = SessionSecrets.parse_raw_secret_imports(prompt, config)
    unless raw_imports.empty?
      imported, _updated_config, masked_prompt = SessionSecrets.import_raw_secret_candidates(prompt, raw_imports, config)
      mode = SessionSecrets.prompt_import_mode(config, runtime)
      if mode == "block"
        resend_delivery = SessionSecrets.prepare_blocked_prompt_resend(masked_prompt, config, runtime)
        return {
          "decision" => "block",
          "reason" => SessionSecrets.build_import_success_message(imported, masked_prompt, resend_delivery: resend_delivery)
        }
      end

      SessionSecrets.queue_pending_scrub(SessionSecrets.extract_session_context(payload), imported, config)
      return {
        "hookSpecificOutput" => {
          "hookEventName" => "UserPromptSubmit",
          "additionalContext" => SessionSecrets.build_import_additional_context(imported, masked_prompt)
        }
      }
    end

    hits = SessionSecrets.find_secret_hits(prompt)
    unless hits.empty?
      return {
        "decision" => "block",
        "reason" => "Potential secret detected in the prompt (#{SessionSecrets.summarize_hits(hits)}). " \
                    "Move credentials to a local environment variable, `.env`, Keychain, 1Password, Vault, or another approved secret source."
      }
    end

    refs = SessionSecrets.parse_inline_secret_refs(prompt, config)
    invalid_ref = refs.find { |ref| !ref.valid? }
    if invalid_ref
      return {
        "decision" => "block",
        "reason" => invalid_ref.error || "Invalid secret reference: #{invalid_ref.raw}"
      }
    end

    return nil if refs.empty?

    rewrite_note =
      if SessionSecrets.runtime_supports_input_rewrite(runtime)
        "Bash commands that keep the `#{SessionSecrets.placeholder_wrap('...')}` placeholders can be rewritten into safe env injection automatically."
      else
        "Codex cannot rewrite `#{SessionSecrets.placeholder_wrap('...')}` placeholders automatically, so resolve each alias from its configured backend before running shell commands."
      end

    {
      "hookSpecificOutput" => {
        "hookEventName" => "UserPromptSubmit",
        "additionalContext" => "The latest prompt already includes configured secret references: #{SessionSecrets.describe_inline_refs(refs)}. " \
                               "Treat them as handles to local secret backends, not as values to print. " \
                               "Do not ask the user to paste the raw credential again. #{rewrite_note} " \
                               "Never write these references or resolved values into files, commits, patches, logs, or chat."
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
  exit(UserPromptSubmitGuard.main)
end
