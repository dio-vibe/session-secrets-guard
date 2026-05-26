#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "common"

module ListAliases
  module_function

  def parse_args(argv)
    options = { "config_path" => nil }
    OptionParser.new do |parser|
      parser.on("--config PATH") { |value| options["config_path"] = value }
      parser.on("--runtime VALUE") { |_value| nil }
    end.parse!(argv)
    options
  end

  def render(config)
    if config.aliases.empty?
      return "No secret aliases configured in `#{config.path}`."
    end

    rows = config.aliases.keys.sort.map do |alias_name|
      target = SessionSecrets.resolve_secret_target(alias_name, config)
      [
        alias_name,
        target.source,
        target.env_name,
        SessionSecrets.describe_secret_target(target)
      ]
    rescue SessionSecrets::SecretResolutionError => e
      [alias_name, "(invalid)", "-", e.message]
    end

    header = ["Alias", "Backend", "Env var", "Location"]
    widths = header.each_with_index.map do |label, index|
      [label.length, *rows.map { |row| row[index].to_s.length }].max
    end

    fmt = ->(cells) { "| #{cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join(" | ")} |" }

    lines = []
    lines << "Configured secret aliases (#{rows.length}) from `#{config.path}`:"
    lines << ""
    lines << fmt.call(header)
    lines << "| #{widths.map { |w| "-" * w }.join(" | ")} |"
    rows.each { |row| lines << fmt.call(row) }
    lines << ""
    lines << "Values are never printed by this command. Use the configured backend (Keychain, dotenv, 1Password, Vault, env) to resolve any alias when actually needed."
    lines.join("\n")
  end

  def main(argv = ARGV)
    options = parse_args(argv)
    config = SessionSecrets.load_secret_config(options["config_path"])
    puts render(config)
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(ListAliases.main)
end
