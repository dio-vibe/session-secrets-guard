#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "optparse"

module MaskEnvFile
  module_function

  KEY_VALUE_PATTERN = /\A(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*)(.*?)(\s*)\z/

  def mask_env_text(text, show_fragments: false)
    text.each_line.map do |line|
      newline = line.end_with?("\n") ? "\n" : ""
      body = newline.empty? ? line : line[0...-1]
      mask_env_line(body, show_fragments: show_fragments) + newline
    end.join
  end

  def mask_env_line(line, show_fragments: false)
    return line if line.strip.empty? || line.lstrip.start_with?("#")

    match = KEY_VALUE_PATTERN.match(line)
    return line if match.nil?

    prefix = match[1]
    raw_value = match[2]
    suffix = match[3]
    "#{prefix}#{mask_value(raw_value, show_fragments: show_fragments)}#{suffix}"
  end

  def mask_value(raw_value, show_fragments: false)
    value = unquote_env_value(raw_value.strip)
    return "<empty>" if value.empty?

    fingerprint = Digest::SHA256.hexdigest(value)[0, 12]
    base = "len=#{value.length} sha256=#{fingerprint}"
    return "<set #{base}>" unless show_fragments

    return "<set #{base}>" if value.length < 8

    "<set #{value[0, 4]}...#{value[-4, 4]} #{base}>"
  end

  def unquote_env_value(value)
    return value if value.length < 2

    first = value[0]
    last = value[-1]
    return value[1...-1] if (first == '"' && last == '"') || (first == "'" && last == "'")

    value
  end

  def main(argv = ARGV)
    show_fragments = false
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby scripts/mask_env_file.rb [--show-fragments] PATH"
      opts.on("--show-fragments", "Show short first/last value fragments in addition to length and fingerprint.") do
        show_fragments = true
      end
    end
    parser.parse!(argv)

    path = argv.shift
    if path.nil? || path.empty?
      warn parser.to_s
      return 2
    end

    $stdout.write(mask_env_text(File.read(path), show_fragments: show_fragments))
    0
  rescue Errno::ENOENT => e
    warn "mask_env_file: #{e.message}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  exit(MaskEnvFile.main)
end
