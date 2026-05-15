#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module PostToolUseGuard
  module_function

  def handle(payload, _runtime)
    SessionSecrets.drain_pending_scrubs(payload)
    tool_response = payload["tool_response"]
    flattened_output = SessionSecrets.flatten_text(tool_response)
    hits = SessionSecrets.find_secret_hits(flattened_output)
    return nil if hits.empty?

    {
      "decision" => "block",
      "reason" => "Potential secret detected in tool output (#{SessionSecrets.summarize_hits(hits)}). " \
                  "Do not reuse or repeat the output. Rerun the step with redacted output and resolve aliases from their configured backends without printing the raw values.",
      "hookSpecificOutput" => {
        "hookEventName" => "PostToolUse",
        "additionalContext" => "Never echo, restate, or commit detected secret values."
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
  exit(PostToolUseGuard.main)
end
