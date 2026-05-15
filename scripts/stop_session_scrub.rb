#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module StopSessionScrub
  module_function

  def handle(payload)
    SessionSecrets.drain_pending_scrubs(payload)
  end

  def main(argv = ARGV)
    OptionParser.new do |parser|
      parser.on("--runtime VALUE") { |_value| nil }
    end.parse!(argv)
    handle(SessionSecrets.load_payload)
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(StopSessionScrub.main)
end
