#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "shellwords"
require "time"

module SessionSecrets
  REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
  DEFAULT_CONFIG_FILE = "session-secrets.toml"
  DEFAULT_DOTENV_FILE = ".env"
  DEFAULT_KEYCHAIN_SERVICE = "session-secrets-guard"
  DEFAULT_CODEX_HOME_DIRNAME = ".codex"
  DEFAULT_PENDING_SCRUBS_FILENAME = "pending_scrubs.json"
  PLACEHOLDER_OPEN = "[" * 2
  PLACEHOLDER_CLOSE = "]" * 2
  INLINE_SECRET_REF_PATTERN = Regexp.new("\\[\\[([^\\[\\]]+)\\]\\]").freeze
  ALIAS_LIKE_PATTERN = /^[a-z]+(?:_[a-z0-9]+)+$/.freeze
  DIRECT_SOURCE_PREFIXES = %w[env dotenv keychain op vault].freeze

  SECRET_PATTERNS = [
    ["github_token", /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{40,})\b/],
    ["openai_key", /\bsk-[A-Za-z0-9]{20,}\b/],
    ["slack_token", /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/],
    ["aws_access_key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
    ["jwt", /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,}\b/],
    ["pem_private_key", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
    [
      "secret_assignment",
      %r{\b(?:token|secret|api[_-]?key|access[_-]?key|password)\b\s*[:=]\s*['"]?[A-Za-z0-9_./+=-]{12,}}i
    ]
  ].freeze

  SENSITIVE_BASH_PATTERNS = [
    [
      "print_secret_env",
      /\b(?:echo|printf|printenv)\b[^\n]*(?:token|secret|api[_-]?key|password|access[_-]?key)/i
    ],
    [
      "dump_secret_file",
      /\bcat\b[^\n]*(?:^|\/)\.?env(?:\.[A-Za-z0-9_-]+)?\b|\bcat\b[^\n]*(?:id_rsa|id_ed25519|\.npmrc|\.pypirc|\.netrc|credentials)\b/i
    ],
    ["gh_auth_token", /\bgh\s+auth\s+token\b/],
    ["onepassword_read", /\bop\s+(?:read|item\s+get)\b/],
    ["vault_read", /\bvault\s+(?:read|kv\s+get)\b/],
    ["aws_secret_lookup", /\baws\s+configure\s+get\s+aws_secret_access_key\b/]
  ].freeze

  ALIAS_HINT_RULES = [
    [/(github|gh|깃허브|깃헙)/i, "github_token", "GITHUB_TOKEN"],
    [/(openai|chatgpt|gpt|오픈에이아이)/i, "openai_api_key", "OPENAI_API_KEY"],
    [/(anthropic|claude|클로드)/i, "anthropic_api_key", "ANTHROPIC_API_KEY"],
    [/(linear|리니어)/i, "linear_api_key", "LINEAR_API_KEY"],
    [/(slack|슬랙)/i, "slack_token", "SLACK_TOKEN"],
    [/(vercel)/i, "vercel_token", "VERCEL_TOKEN"],
    [/(npm)/i, "npm_token", "NPM_TOKEN"],
    [/(stripe)/i, "stripe_api_key", "STRIPE_API_KEY"],
    [/(sentry)/i, "sentry_auth_token", "SENTRY_AUTH_TOKEN"],
    [/(cloudflare)/i, "cloudflare_api_token", "CLOUDFLARE_API_TOKEN"]
  ].freeze

  DATABASE_HINT_PATTERN = /(database|db|postgres|postgresql|mysql|mongodb|redis|rds|supabase|neon|데이터베이스)/i.freeze
  PASSWORD_HINT_PATTERN = /(password|passwd|pwd|비밀번호|패스워드)/i.freeze
  API_KEY_HINT_PATTERN = /(api[ _-]?key|access[ _-]?key|키)/i.freeze
  TOKEN_HINT_PATTERN = /(token|bearer|토큰)/i.freeze
  SECRET_HINT_PATTERN = /(secret|credential|credentials|시크릿|자격증명)/i.freeze

  class SecretResolutionError < StandardError; end

  SecretConfig = Struct.new(:path, :defaults, :aliases, keyword_init: true)
  SecretTarget = Struct.new(:spec, :source, :env_name, :metadata, keyword_init: true)
  RawSecretImport = Struct.new(:raw, :body, :start, :stop, :context_snippet, keyword_init: true)
  ImportedSecret = Struct.new(:raw, :alias_name, :env_name, :backend, :target, keyword_init: true)
  SessionContext = Struct.new(:thread_id, :session_id, :rollout_path, :transcript_path, :cwd, keyword_init: true)
  PendingSessionScrub = Struct.new(
    :thread_id,
    :session_id,
    :rollout_path,
    :transcript_path,
    :cwd,
    :config_path,
    :aliases,
    :created_at,
    keyword_init: true
  )

  class InlineSecretRef < Struct.new(:raw, :body, :spec, :target, :error, keyword_init: true)
    def valid?
      !target.nil? && error.nil?
    end

    def env_name
      target ? target.env_name : SessionSecrets.sanitize_env_name(body)
    end
  end

  module_function

  def placeholder_wrap(value)
    "#{PLACEHOLDER_OPEN}#{value}#{PLACEHOLDER_CLOSE}"
  end

  def system_ruby_path
    "/usr/bin/ruby"
  end

  def load_payload
    raw = $stdin.read
    return {} if raw.nil? || raw.strip.empty?

    payload = JSON.parse(raw)
    payload.is_a?(Hash) ? payload : {}
  rescue JSON::ParserError
    {}
  end

  def emit_json(payload)
    $stdout.write(JSON.generate(payload))
  end

  def codex_home
    configured = ENV["CODEX_HOME"]
    return Pathname.new(File.expand_path(configured)) unless configured.nil? || configured.empty?

    Pathname.new(File.expand_path("~")).join(DEFAULT_CODEX_HOME_DIRNAME)
  end

  def codex_state_db_path
    codex_home.join("state_5.sqlite")
  end

  def codex_history_path
    codex_home.join("history.jsonl")
  end

  def pending_scrubs_path
    configured = ENV["SESSION_SECRETS_PENDING_SCRUBS"]
    return Pathname.new(File.expand_path(configured)) unless configured.nil? || configured.empty?

    codex_home.join(DEFAULT_PENDING_SCRUBS_FILENAME)
  end

  def flatten_text(value)
    parts = []
    collect_text(value, parts)
    parts.reject(&:empty?).join("\n")
  end

  def collect_text(value, parts)
    case value
    when nil
      nil
    when String
      parts << value
    when Hash
      value.each_value { |nested| collect_text(nested, parts) }
    when Array
      value.each { |nested| collect_text(nested, parts) }
    else
      parts << value.to_s
    end
  end

  def extract_session_context(payload)
    SessionContext.new(
      thread_id: find_first_string(payload, %w[thread_id threadId]),
      session_id: find_first_string(payload, %w[session_id sessionId]),
      rollout_path: find_first_string(payload, %w[rollout_path rolloutPath]),
      transcript_path: find_first_string(payload, %w[transcript_path transcriptPath]),
      cwd: find_first_string(payload, %w[cwd])
    )
  end

  def find_first_string(value, candidate_keys)
    case value
    when Hash
      candidate_keys.each do |key|
        nested = value[key]
        return nested if nested.is_a?(String) && !nested.strip.empty?
      end
      value.each_value do |nested|
        found = find_first_string(nested, candidate_keys)
        return found unless found.nil?
      end
    when Array
      value.each do |nested|
        found = find_first_string(nested, candidate_keys)
        return found unless found.nil?
      end
    end
    nil
  end

  def load_secret_config(config_path = nil)
    candidates = []
    if config_path
      candidates << Pathname.new(File.expand_path(config_path.to_s))
    elsif ENV["SESSION_SECRETS_CONFIG"]
      candidates << Pathname.new(File.expand_path(ENV["SESSION_SECRETS_CONFIG"]))
    else
      candidates << REPO_ROOT.join(DEFAULT_CONFIG_FILE)
    end

    candidates.each do |candidate|
      next unless candidate.exist?

      raw = load_toml_mapping(candidate)
      defaults = raw["defaults"].is_a?(Hash) ? deep_dup_hash(raw["defaults"]) : {}
      aliases = raw["aliases"].is_a?(Hash) ? deep_dup_hash(raw["aliases"]) : {}
      return SecretConfig.new(path: candidate, defaults: defaults, aliases: aliases)
    end

    preferred = candidates.first || REPO_ROOT.join(DEFAULT_CONFIG_FILE)
    SecretConfig.new(path: preferred, defaults: {}, aliases: {})
  end

  def load_toml_mapping(path)
    parse_simple_toml(path.read)
  end

  def parse_simple_toml(text)
    root = {}
    current = root

    text.each_line do |raw_line|
      line = strip_toml_comment(raw_line).strip
      next if line.empty?

      if line.start_with?("[") && line.end_with?("]")
        section_path = line[1..-2].split(".").map(&:strip).reject(&:empty?)
        current = ensure_toml_path(root, section_path)
        next
      end

      next unless line.include?("=")

      key, value = line.split("=", 2)
      current[key.strip] = parse_simple_toml_value(value.strip)
    end

    root
  end

  def strip_toml_comment(line)
    in_quote = false
    quote_char = nil
    escaped = false
    chars = line.chars

    chars.each_with_index do |char, index|
      if escaped
        escaped = false
        next
      end

      if char == "\\" && in_quote
        escaped = true
        next
      end

      if (char == '"' || char == "'")
        if in_quote && quote_char == char
          in_quote = false
          quote_char = nil
        elsif !in_quote
          in_quote = true
          quote_char = char
        end
        next
      end

      return line[0...index] if char == "#" && !in_quote
    end

    line
  end

  def ensure_toml_path(root, section_path)
    current = root
    section_path.each do |part|
      current[part] = {} unless current[part].is_a?(Hash)
      current = current[part]
    end
    current
  end

  def parse_simple_toml_value(value)
    stripped = value.strip
    return true if stripped == "true"
    return false if stripped == "false"
    return stripped.to_i if stripped.match?(/\A-?\d+\z/)
    return stripped.to_f if stripped.match?(/\A-?\d+\.\d+\z/)
    return parse_toml_array(stripped[1..-2]) if stripped.start_with?("[") && stripped.end_with?("]")
    return parse_quoted_toml_string(stripped) if quoted_toml_string?(stripped)

    stripped
  end

  def parse_toml_array(body)
    items = []
    current = +""
    in_quote = false
    quote_char = nil
    escaped = false

    body.chars.each do |char|
      if escaped
        current << char
        escaped = false
        next
      end

      if char == "\\" && in_quote
        current << char
        escaped = true
        next
      end

      if char == '"' || char == "'"
        if in_quote && quote_char == char
          in_quote = false
          quote_char = nil
        elsif !in_quote
          in_quote = true
          quote_char = char
        end
        current << char
        next
      end

      if char == "," && !in_quote
        stripped = current.strip
        items << parse_simple_toml_value(stripped) unless stripped.empty?
        current = +""
      else
        current << char
      end
    end

    stripped = current.strip
    items << parse_simple_toml_value(stripped) unless stripped.empty?
    items
  end

  def quoted_toml_string?(value)
    value.length >= 2 && ((value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'")))
  end

  def parse_quoted_toml_string(value)
    inner = value[1...-1]
    return inner if value.start_with?("'")

    inner.gsub(/\\([\\"])/, '\1')
  end

  def deep_dup_hash(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), memo| memo[key] = deep_dup_hash(nested) }
    when Array
      value.map { |item| deep_dup_hash(item) }
    else
      value
    end
  end

  def secret_config_display_path(config)
    return "(missing #{DEFAULT_CONFIG_FILE})" if config.path.nil?
    return config.path.to_s if config.path.exist?

    "(missing #{config.path})"
  end

  def sanitize_env_name(value)
    env_name = value.to_s.gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").upcase
    env_name = "SECRET" if env_name.empty?
    env_name = "SECRET_#{env_name}" unless env_name.match?(/\A[A-Z_]/)
    env_name
  end

  def find_secret_hits(text)
    scrubbed = text.gsub(INLINE_SECRET_REF_PATTERN, "[secret-ref]")
    SECRET_PATTERNS.each_with_object([]) do |(name, pattern), hits|
      hits << name if pattern.match?(scrubbed)
    end
  end

  def find_sensitive_bash_hits(command)
    SENSITIVE_BASH_PATTERNS.each_with_object([]) do |(name, pattern), hits|
      hits << name if pattern.match?(command)
    end
  end

  def summarize_hits(hits)
    return "possible secret material" if hits.nil? || hits.empty?

    hits.first(3).join(", ")
  end

  def parse_inline_secret_refs(text, config)
    refs = []
    text.to_s.to_enum(:scan, INLINE_SECRET_REF_PATTERN).each do
      match = Regexp.last_match
      raw = match[0]
      body = match[1].strip
      parsed = parse_inline_secret_ref(raw, body, config)
      refs << parsed unless parsed.nil?
    end
    refs
  end

  def parse_raw_secret_imports(text, config)
    imports = []
    text.to_s.to_enum(:scan, INLINE_SECRET_REF_PATTERN).each do
      match = Regexp.last_match
      raw = match[0]
      body = match[1].strip
      next unless parse_inline_secret_ref(raw, body, config).nil?
      next if body.empty?

      imports << RawSecretImport.new(
        raw: raw,
        body: body,
        start: match.begin(0),
        stop: match.end(0),
        context_snippet: build_context_snippet(text, match.begin(0), match.end(0))
      )
    end
    imports
  end

  def build_context_snippet(text, start_index, stop_index, radius = 80)
    before = text[[0, start_index - radius].max...start_index]
    after = text[stop_index...[text.length, stop_index + radius].min]
    "#{before}[secret]#{after}"
  end

  def parse_inline_secret_ref(raw, body, config)
    explicit_ref = body.start_with?("secret:")
    direct_ref = DIRECT_SOURCE_PREFIXES.any? { |prefix| body.start_with?("#{prefix}:") }
    alias_ref = config.aliases.key?(body)
    alias_like_ref = ALIAS_LIKE_PATTERN.match?(body) && body.length <= 24
    return nil unless explicit_ref || direct_ref || alias_ref || alias_like_ref

    if alias_like_ref && !alias_ref && !explicit_ref && !direct_ref
      return InlineSecretRef.new(raw: raw, body: body, spec: body, target: nil, error: "Unknown secret alias: #{body}")
    end

    spec = explicit_ref ? body.sub(/\Asecret:/, "") : body
    target = resolve_secret_target(spec, config)
    InlineSecretRef.new(raw: raw, body: body, spec: spec, target: target, error: nil)
  rescue SecretResolutionError => e
    InlineSecretRef.new(raw: raw, body: body, spec: spec, target: nil, error: e.message)
  end

  def resolve_secret_target(spec, config)
    return target_from_alias(spec, config.aliases[spec]) if config.aliases.key?(spec)

    prefix, remainder = spec.split(":", 2)
    if remainder && DIRECT_SOURCE_PREFIXES.include?(prefix)
      return target_from_direct_source(prefix, remainder, config)
    end

    raise SecretResolutionError, "Unknown secret alias or unsupported secret source: #{spec}"
  end

  def target_from_alias(alias_name, alias_data)
    source = alias_data["source"].to_s.strip
    raise SecretResolutionError, "Alias `#{alias_name}` is missing `source`." if source.empty?

    env_name = alias_data["env_name"] ? alias_data["env_name"].to_s : sanitize_env_name(alias_name)
    metadata = deep_dup_hash(alias_data)
    metadata["alias"] = alias_name
    SecretTarget.new(spec: alias_name, source: source, env_name: env_name, metadata: metadata)
  end

  def target_from_direct_source(source, remainder, config)
    case source
    when "env"
      key = remainder.strip
      raise SecretResolutionError, "`env:` references must include an environment variable name." if key.empty?

      SecretTarget.new(spec: "env:#{key}", source: "env", env_name: sanitize_env_name(key), metadata: { "name" => key })
    when "dotenv"
      path_part, key = split_path_and_key(remainder, default_dotenv_path(config), "dotenv")
      SecretTarget.new(
        spec: "dotenv:#{path_part}##{key}",
        source: "dotenv",
        env_name: sanitize_env_name(key),
        metadata: { "path" => path_part, "key" => key }
      )
    when "keychain"
      service, account = split_keychain_reference(remainder)
      metadata = { "service" => service }
      metadata["account"] = account unless account.nil?
      SecretTarget.new(
        spec: "keychain:#{remainder}",
        source: "keychain",
        env_name: sanitize_env_name(account || service),
        metadata: metadata
      )
    when "op"
      secret_ref = remainder.start_with?("op://") ? remainder : "op://#{remainder}"
      env_hint = secret_ref.sub(/\/+\z/, "").split("/").last
      SecretTarget.new(
        spec: "op:#{secret_ref}",
        source: "op",
        env_name: sanitize_env_name(env_hint),
        metadata: { "secret_ref" => secret_ref }
      )
    when "vault"
      path_part, field = split_path_and_key(remainder, "", "vault")
      mount, secret_path = split_mount_and_path(path_part)
      SecretTarget.new(
        spec: "vault:#{mount}/#{secret_path}##{field}",
        source: "vault",
        env_name: sanitize_env_name(field),
        metadata: { "mount" => mount, "path" => secret_path, "field" => field }
      )
    else
      raise SecretResolutionError, "Unsupported direct secret source: #{source}"
    end
  end

  def split_path_and_key(reference, default_path, source_name)
    raise SecretResolutionError, "`#{source_name}:` references must include `#KEY`." unless reference.include?("#")

    split_index = reference.rindex("#")
    path_part = split_index.nil? ? nil : reference[0...split_index]
    key = split_index.nil? ? nil : reference[(split_index + 1)..]
    path_part = default_path if path_part.nil? || path_part.empty?
    raise SecretResolutionError, "`#{source_name}:` references must include both a path and a key." if path_part.nil? || path_part.empty? || key.nil? || key.empty?

    [path_part, key]
  end

  def split_keychain_reference(reference)
    parts = reference.split("/", 2)
    service = parts[0].to_s.strip
    account = parts.length > 1 ? parts[1].to_s.strip : nil
    account = nil if account&.empty?
    raise SecretResolutionError, "`keychain:` references must include a service name." if service.empty?

    [service, account]
  end

  def split_mount_and_path(reference)
    raise SecretResolutionError, "`vault:` references must include `mount/path#field`." unless reference.include?("/")

    mount, path = reference.split("/", 2)
    mount = mount.to_s.strip
    path = path.to_s.strip
    raise SecretResolutionError, "`vault:` references must include `mount/path#field`." if mount.empty? || path.empty?

    [mount, path]
  end

  def resolve_secret_value(target, config)
    case target.source
    when "env"
      name = target.metadata["name"].to_s
      value = ENV[name]
      raise SecretResolutionError, "Environment variable `#{name}` is not set." if value.nil? || value.empty?

      value
    when "dotenv"
      path = resolve_config_relative_path(target.metadata["path"].to_s, config)
      key = target.metadata["key"].to_s
      values = load_dotenv_file(path)
      value = values[key]
      raise SecretResolutionError, "`#{key}` was not found in `#{path}`." if value.nil? || value.empty?

      value
    when "keychain"
      command = ["security", "find-generic-password", "-s", target.metadata["service"].to_s, "-w"]
      account = target.metadata["account"]
      command.concat(["-a", account.to_s]) unless account.nil?
      run_secret_command(command).sub(/\n+\z/, "")
    when "op"
      run_secret_command(["op", "read", target.metadata["secret_ref"].to_s]).sub(/\n+\z/, "")
    when "vault"
      mount = target.metadata["mount"].to_s
      secret_path = target.metadata["path"].to_s
      field = target.metadata["field"].to_s
      run_secret_command(["vault", "kv", "get", "-mount=#{mount}", "-field=#{field}", secret_path]).sub(/\n+\z/, "")
    when "command"
      run_secret_command(build_command_backend_command(target)).sub(/\n+\z/, "")
    else
      raise SecretResolutionError, "Unsupported secret source: #{target.source}"
    end
  end

  def run_secret_command(command, shell: false)
    executable = command[0].to_s
    if !shell && !executable.empty? && find_executable(executable).nil?
      raise SecretResolutionError, "Required executable `#{executable}` is not installed."
    end

    stdout, stderr, status =
      if shell
        Open3.capture3(command.join(" "))
      else
        Open3.capture3(*command.map(&:to_s))
      end
    return stdout if status.success?

    error_text = [stderr.strip, stdout.strip].find { |value| !value.empty? } || "exit code #{status.exitstatus}"
    raise SecretResolutionError, error_text
  end

  def find_executable(name)
    return name if name.include?("/") && File.executable?(name)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, name)
      return candidate if File.executable?(candidate) && !File.directory?(candidate)
    end
    nil
  end

  def secret_runner_path
    REPO_ROOT.join("scripts", "run_with_secrets.sh")
  end

  def secret_runner_command_prefix
    [secret_runner_path.to_s]
  end

  def build_command_backend_command(target)
    command = target.metadata["command"]
    if command.is_a?(String) && !command.strip.empty?
      Shellwords.split(command)
    elsif command.is_a?(Array) && command.all? { |part| part.is_a?(String) }
      command
    else
      alias_name = target.metadata["alias"] || target.spec
      raise SecretResolutionError, "Alias `#{alias_name}` has invalid `command` configuration."
    end
  end

  def resolve_config_relative_path(path_value, config)
    path = Pathname.new(path_value.to_s)
    return path.expand_path if path.absolute?

    base = config.path ? config.path.dirname.expand_path : REPO_ROOT
    base.join(path).cleanpath
  end

  def load_dotenv_file(path)
    raise SecretResolutionError, "dotenv file `#{path}` does not exist." unless path.exist?

    values = {}
    path.read.each_line do |raw_line|
      line = raw_line.strip
      next if line.empty? || line.start_with?("#") || !line.include?("=")

      key, value = line.split("=", 2)
      key = key.strip
      value = value.strip
      if quoted_toml_string?(value)
        value = parse_quoted_toml_string(value)
      else
        value = value.split(" #", 2).first.to_s.rstrip
      end
      values[key] = value
    end
    values
  end

  def build_runtime_secret_spec(target, config)
    case target.source
    when "env"
      "env:#{target.metadata["name"]}"
    when "dotenv"
      path = resolve_config_relative_path(target.metadata["path"].to_s, config)
      "dotenv:#{path}##{target.metadata["key"]}"
    when "keychain"
      service = target.metadata["service"].to_s
      account = target.metadata["account"]
      account ? "keychain:#{service}/#{account}" : "keychain:#{service}"
    when "op"
      "op:#{target.metadata["secret_ref"]}"
    when "vault"
      mount = target.metadata["mount"].to_s
      secret_path = target.metadata["path"].to_s
      field = target.metadata["field"].to_s
      "vault:#{mount}/#{secret_path}##{field}"
    when "command"
      shell_command = build_command_backend_command(target).map { |part| Shellwords.escape(part) }.join(" ")
      "command-b64:#{Base64.strict_encode64(shell_command)}"
    else
      raise SecretResolutionError, "Unsupported secret source for runtime injection: #{target.source}"
    end
  end

  def build_secret_run_command(command, refs, config)
    rewritten_command = command.dup
    bindings = []
    seen_bindings = {}

    refs.each do |ref|
      raise SecretResolutionError, ref.error || "Invalid secret reference: #{ref.raw}" unless ref.valid?

      rewritten_command = rewritten_command.gsub(ref.raw, "$#{ref.target.env_name}")
      binding = [ref.target.env_name, build_runtime_secret_spec(ref.target, config)]
      next if seen_bindings[binding]

      bindings << binding
      seen_bindings[binding] = true
    end

    parts = secret_runner_command_prefix.dup
    bindings.each { |env_name, spec| parts.concat(["--set", "#{env_name}=#{spec}"]) }
    parts.concat(["--", "bash", "-lc", rewritten_command])
    parts.map { |part| Shellwords.escape(part) }.join(" ")
  end

  def describe_inline_refs(refs)
    refs.map do |ref|
      if ref.target.nil?
        "#{ref.raw} (invalid)"
      else
        "#{ref.raw} -> #{ref.target.env_name} via #{describe_secret_target(ref.target)}"
      end
    end.join(", ")
  end

  def describe_secret_target(target)
    case target.source
    when "env"
      "env(name=#{target.metadata["name"]})"
    when "dotenv"
      "dotenv(path=#{target.metadata["path"]}, key=#{target.metadata["key"]})"
    when "keychain"
      service = target.metadata["service"]
      account = target.metadata["account"]
      account ? "keychain(service=#{service}, account=#{account})" : "keychain(service=#{service})"
    when "op"
      "op(secret_ref=#{target.metadata["secret_ref"]})"
    when "vault"
      "vault(mount=#{target.metadata["mount"]}, path=#{target.metadata["path"]}, field=#{target.metadata["field"]})"
    when "command"
      "command(alias=#{target.metadata["alias"] || target.spec})"
    else
      target.source
    end
  end

  def describe_native_resolution(target)
    case target.source
    when "env"
      "read environment variable #{target.metadata["name"]}"
    when "dotenv"
      "read key #{target.metadata["key"]} from dotenv file #{target.metadata["path"]}"
    when "keychain"
      service = target.metadata["service"]
      account = target.metadata["account"]
      account ? "read macOS Keychain item service=#{service} account=#{account} via `security find-generic-password`" :
        "read macOS Keychain item service=#{service} via `security find-generic-password`"
    when "op"
      "read 1Password secret ref #{target.metadata["secret_ref"]}"
    when "vault"
      "read Vault mount=#{target.metadata["mount"]} path=#{target.metadata["path"]} field=#{target.metadata["field"]}"
    when "command"
      "run the configured local command backend"
    else
      "read backend #{target.source}"
    end
  end

  def describe_imported_secret(item)
    "#{placeholder_wrap(item.alias_name)} stored at #{describe_secret_target(item.target)}"
  end

  def runtime_supports_input_rewrite(runtime)
    runtime == "claude"
  end

  def is_secret_runner_command(command)
    command.include?("run_with_secrets.sh")
  end

  def source_availability(source)
    case source
    when "env"
      [true, "available via current environment"]
    when "dotenv"
      [true, "available via local dotenv file"]
    when "keychain"
      [RUBY_PLATFORM.include?("darwin") && !find_executable("security").nil?, "uses macOS `security`"]
    when "op"
      [!find_executable("op").nil?, "uses 1Password CLI `op`"]
    when "vault"
      [!find_executable("vault").nil?, "uses HashiCorp Vault CLI `vault`"]
    when "command"
      [true, "uses configured local command"]
    else
      [false, "unsupported source `#{source}`"]
    end
  end

  def default_dotenv_path(config)
    (config.defaults["import_dotenv_path"] || config.defaults["default_dotenv_path"] || DEFAULT_DOTENV_FILE).to_s
  end

  def default_keychain_service(config)
    (config.defaults["keychain_service"] || DEFAULT_KEYCHAIN_SERVICE).to_s
  end

  def default_import_backend(config)
    (config.defaults["import_backend"] || "auto").to_s
  end

  def prompt_import_mode(config, runtime)
    runtime_key = "#{runtime}_prompt_import_mode"
    configured = config.defaults[runtime_key] || config.defaults["prompt_import_mode"]
    mode = if configured
      configured.to_s.strip.downcase.tr("-", "_")
    else
      runtime == "codex" ? "allow_and_scrub" : "block"
    end
    raise SecretResolutionError, "Unsupported prompt import mode `#{mode}`. Supported values are `block` and `allow_and_scrub`." unless %w[block allow_and_scrub].include?(mode)

    mode
  end

  def resolve_import_backend(config, backend_override = nil)
    backend = (backend_override || default_import_backend(config)).strip.downcase
    if backend == "auto"
      return "keychain" if RUBY_PLATFORM.include?("darwin") && !find_executable("security").nil?

      return "dotenv"
    end
    raise SecretResolutionError, "Unsupported import backend `#{backend}`. Supported backends are `auto`, `keychain`, and `dotenv`." unless %w[keychain dotenv].include?(backend)
    if backend == "keychain" && !(RUBY_PLATFORM.include?("darwin") && !find_executable("security").nil?)
      raise SecretResolutionError, "The `keychain` import backend requires macOS `security`."
    end
    backend
  end

  def infer_alias_base(context_snippet, masked_prompt)
    hint_text = "#{context_snippet}\n#{masked_prompt}"
    ALIAS_HINT_RULES.each do |pattern, alias_name, env_name|
      return [alias_name, env_name] if pattern.match?(hint_text)
    end

    return ["database_password", "DATABASE_PASSWORD"] if DATABASE_HINT_PATTERN.match?(hint_text) && PASSWORD_HINT_PATTERN.match?(hint_text)
    return ["database_secret", "DATABASE_SECRET"] if DATABASE_HINT_PATTERN.match?(hint_text)
    return ["account_password", "ACCOUNT_PASSWORD"] if PASSWORD_HINT_PATTERN.match?(hint_text)
    return ["api_key", "API_KEY"] if API_KEY_HINT_PATTERN.match?(hint_text)
    return ["access_token", "ACCESS_TOKEN"] if TOKEN_HINT_PATTERN.match?(hint_text)
    return ["session_secret", "SESSION_SECRET"] if SECRET_HINT_PATTERN.match?(hint_text)

    ["session_secret", "SESSION_SECRET"]
  end

  def next_unique_name(base, existing_names)
    return base unless existing_names.include?(base)

    suffix = 2
    suffix += 1 while existing_names.include?("#{base}_#{suffix}")
    "#{base}_#{suffix}"
  end

  def mask_prompt_with_placeholder(prompt, imports)
    masked = prompt.dup
    imports.each { |raw_import| masked = masked.sub(raw_import.raw, "[secret]") }
    masked
  end

  def mask_prompt_with_aliases(prompt, imported)
    masked = prompt.dup
    imported.each { |item| masked = masked.sub(item.raw, placeholder_wrap(item.alias_name)) }
    masked
  end

  def import_raw_secret_candidates(prompt, imports, config, backend_override = nil)
    mutable_config = config
    masked_prompt = mask_prompt_with_placeholder(prompt, imports)
    existing_alias_names = mutable_config.aliases.keys
    existing_env_names = mutable_config.aliases.values.map { |alias_data| alias_data["env_name"] }.compact.map(&:to_s)
    imported_items = []

    imports.each do |raw_import|
      alias_base, env_base = infer_alias_base(raw_import.context_snippet, masked_prompt)
      alias_name = next_unique_name(alias_base, existing_alias_names)
      env_name = next_unique_name(env_base, existing_env_names)
      target, mutable_config, backend = store_imported_secret(raw_import.body, alias_name, env_name, mutable_config, backend_override)
      imported_items << ImportedSecret.new(raw: raw_import.raw, alias_name: alias_name, env_name: env_name, backend: backend, target: target)
      existing_alias_names << alias_name
      existing_env_names << env_name
    end

    [imported_items, mutable_config, mask_prompt_with_aliases(prompt, imported_items)]
  end

  def import_secret_value(secret_value, context_text:, config:, alias_name: nil, backend_override: nil)
    alias_base, env_base = infer_alias_base(context_text, context_text)
    existing_alias_names = config.aliases.keys
    existing_env_names = config.aliases.values.map { |alias_data| alias_data["env_name"] }.compact.map(&:to_s)
    final_alias = alias_name || next_unique_name(alias_base, existing_alias_names)
    env_base_to_use = alias_name ? sanitize_env_name(alias_name) : env_base
    final_env_name = next_unique_name(env_base_to_use, existing_env_names)
    target, updated_config, backend = store_imported_secret(secret_value, final_alias, final_env_name, config, backend_override)
    [
      ImportedSecret.new(raw: "", alias_name: final_alias, env_name: final_env_name, backend: backend, target: target),
      updated_config
    ]
  end

  def store_imported_secret(secret_value, alias_name, env_name, config, backend_override = nil)
    backend = resolve_import_backend(config, backend_override)
    alias_data =
      case backend
      when "keychain"
        store_secret_in_keychain(secret_value, alias_name, env_name, config)
      when "dotenv"
        store_secret_in_dotenv(secret_value, alias_name, env_name, config)
      else
        raise SecretResolutionError, "Unsupported import backend: #{backend}"
      end

    updated_config = upsert_secret_alias(alias_name, alias_data, config)
    target = resolve_secret_target(alias_name, updated_config)
    [target, updated_config, backend]
  end

  def store_secret_in_keychain(secret_value, alias_name, env_name, config)
    service = default_keychain_service(config)
    run_secret_command(["security", "add-generic-password", "-U", "-a", alias_name, "-s", service, "-w", secret_value])
    {
      "env_name" => env_name,
      "source" => "keychain",
      "service" => service,
      "account" => alias_name
    }
  end

  def store_secret_in_dotenv(secret_value, alias_name, env_name, config)
    raise SecretResolutionError, "The `dotenv` import backend does not support multiline secrets. Use `keychain` instead." if secret_value.include?("\n") || secret_value.include?("\r")

    path_spec = default_dotenv_path(config)
    path = resolve_config_relative_path(path_spec, config)
    upsert_dotenv_var(path, env_name, secret_value)
    {
      "env_name" => env_name,
      "source" => "dotenv",
      "path" => Pathname.new(path_spec).absolute? ? path.to_s : path_spec,
      "key" => env_name,
      "imported_as" => alias_name
    }
  end

  def upsert_dotenv_var(path, key, value)
    path.dirname.mkpath
    encoded_line = "#{key}=#{format_dotenv_value(value)}"
    unless path.exist?
      path.write("#{encoded_line}\n")
      return
    end

    pattern = /^\s*#{Regexp.escape(key)}\s*=/
    lines = path.read.split("\n", -1)
    replaced = false
    updated = lines.map do |line|
      if line.match?(pattern)
        replaced = true
        encoded_line
      else
        line
      end
    end
    unless replaced
      updated << "" if !updated.empty? && !updated.last.strip.empty?
      updated << encoded_line
    end
    path.write(updated.join("\n").sub(/\n*\z/, "\n"))
  end

  def format_dotenv_value(value)
    "\"#{value.gsub("\\", "\\\\\\\\").gsub('"', '\"')}\""
  end

  def upsert_secret_alias(alias_name, alias_data, config)
    path = config.path || REPO_ROOT.join(DEFAULT_CONFIG_FILE)
    defaults = deep_dup_hash(config.defaults)
    defaults["import_backend"] ||= "auto"
    defaults["prompt_import_mode"] ||= "allow_and_scrub"
    defaults["default_dotenv_path"] ||= DEFAULT_DOTENV_FILE
    defaults["keychain_service"] ||= DEFAULT_KEYCHAIN_SERVICE
    aliases = deep_dup_hash(config.aliases)
    aliases[alias_name] = deep_dup_hash(alias_data)
    path.dirname.mkpath
    path.write(render_secret_config(defaults, aliases))
    SecretConfig.new(path: path, defaults: defaults, aliases: aliases)
  end

  def render_secret_config(defaults, aliases)
    lines = []
    unless defaults.empty?
      lines << "[defaults]"
      defaults.keys.sort.each { |key| lines << "#{key} = #{render_toml_value(defaults[key])}" }
      lines << ""
    end

    aliases.keys.sort.each do |alias_name|
      lines << "[aliases.#{alias_name}]"
      aliases[alias_name].keys.sort.each do |key|
        lines << "#{key} = #{render_toml_value(aliases[alias_name][key])}"
      end
      lines << ""
    end

    lines.join("\n").rstrip + "\n"
  end

  def render_toml_value(value)
    case value
    when true then "true"
    when false then "false"
    when Integer, Float then value.to_s
    when String then "\"#{value.gsub("\\", "\\\\\\\\").gsub('"', '\"')}\""
    when Array then "[" + value.map { |item| render_toml_value(item) }.join(", ") + "]"
    else
      raise SecretResolutionError, "Unsupported config value type for TOML rendering: #{value.class}"
    end
  end

  def build_import_additional_context(imported, masked_prompt)
    alias_pairs = imported.each_with_index.map { |item, index| "##{index + 1} -> #{describe_imported_secret(item)}" }.join(", ")
    message = +"The latest user prompt pasted raw #{placeholder_wrap("...")} placeholders, and they were imported into local secret storage. "
    message << "Use these alias mappings in encounter order: #{alias_pairs}. "
    message << "From this point on, refer only to the generated aliases, never the raw placeholder contents. "
    message << "If a command needs one of these credentials, resolve the alias from its configured backend at the moment of use. "
    message << "Do not write alias mappings or resolved values into files, commits, patches, or logs. "
    message << "A local Codex history scrub has been queued for this session."
    message << " Safe prompt shape: #{masked_prompt}" if masked_prompt && masked_prompt.length <= 240
    message
  end

  def build_import_success_message(imported, masked_prompt)
    aliases_text = imported.map { |item| placeholder_wrap(item.alias_name) }.join(", ")
    backend_names = imported.map(&:backend).uniq.sort.join(", ")
    count_text = imported.length == 1 ? "secret" : "secrets"
    message = "Stored #{imported.length} #{count_text} locally via #{backend_names} as #{aliases_text}. "
    message << "The raw placeholder was blocked before it reached the model. Send the same request again using only those aliases."
    message << " Suggested resend: #{masked_prompt}" if masked_prompt && masked_prompt.length <= 240
    message
  end

  def build_scrub_replacements_from_aliases(alias_names, config)
    replacements = []
    seen = {}
    alias_names.each do |alias_name|
      target = resolve_secret_target(alias_name, config)
      raw_secret = resolve_secret_value(target, config)
      replacement = placeholder_wrap(alias_name)
      [placeholder_wrap(raw_secret), raw_secret].each do |raw_value|
        next if raw_value.nil? || raw_value.empty?
        pair = [raw_value, replacement]
        next if seen[pair]

        replacements << { "raw" => raw_value, "replacement" => replacement }
        seen[pair] = true
      end
    end
    replacements
  end

  def load_pending_scrubs
    path = pending_scrubs_path
    return [] unless path.exist?

    raw_entries = JSON.parse(path.read)
    return [] unless raw_entries.is_a?(Array)

    raw_entries.each_with_object([]) do |raw_entry, entries|
      next unless raw_entry.is_a?(Hash)
      aliases = raw_entry["aliases"]
      next unless aliases.is_a?(Array)

      cleaned_aliases = aliases.select { |alias_name| alias_name.is_a?(String) && !alias_name.strip.empty? }
      next if cleaned_aliases.empty?

      entries << PendingSessionScrub.new(
        thread_id: optional_str(raw_entry["thread_id"]),
        session_id: optional_str(raw_entry["session_id"]),
        rollout_path: optional_str(raw_entry["rollout_path"]),
        transcript_path: optional_str(raw_entry["transcript_path"]),
        cwd: optional_str(raw_entry["cwd"]),
        config_path: optional_str(raw_entry["config_path"]),
        aliases: cleaned_aliases,
        created_at: (raw_entry["created_at"] || 0).to_i
      )
    end
  rescue JSON::ParserError
    []
  end

  def save_pending_scrubs(entries)
    path = pending_scrubs_path
    path.dirname.mkpath
    serialized = entries.map do |entry|
      {
        "thread_id" => entry.thread_id,
        "session_id" => entry.session_id,
        "rollout_path" => entry.rollout_path,
        "transcript_path" => entry.transcript_path,
        "cwd" => entry.cwd,
        "config_path" => entry.config_path,
        "aliases" => entry.aliases,
        "created_at" => entry.created_at
      }
    end
    path.write(JSON.pretty_generate(serialized) + "\n")
  end

  def queue_pending_scrub(session_context, imported, config)
    aliases = imported.map(&:alias_name).compact.reject(&:empty?)
    return if aliases.empty?

    entries = load_pending_scrubs
    entries << PendingSessionScrub.new(
      thread_id: session_context.thread_id,
      session_id: session_context.session_id,
      rollout_path: session_context.rollout_path,
      transcript_path: session_context.transcript_path,
      cwd: session_context.cwd,
      config_path: config.path ? config.path.to_s : nil,
      aliases: aliases,
      created_at: Time.now.to_i
    )
    save_pending_scrubs(entries)
  end

  def drain_pending_scrubs(payload)
    session_context = extract_session_context(payload)
    entries = load_pending_scrubs
    return { "matched" => 0, "scrubbed" => 0 } if entries.empty?

    matched = []
    remaining = []
    entries.each do |entry|
      if pending_scrub_matches(entry, session_context)
        matched << entry
      else
        remaining << entry
      end
    end

    scrubbed_count = 0
    matched.each do |entry|
      if apply_pending_scrub(entry)
        scrubbed_count += 1
      else
        remaining << entry
      end
    end

    save_pending_scrubs(remaining) if remaining.length != entries.length
    { "matched" => matched.length, "scrubbed" => scrubbed_count }
  end

  def pending_scrub_matches(entry, session_context)
    return true if entry.thread_id && session_context.thread_id && entry.thread_id == session_context.thread_id
    return true if entry.session_id && session_context.session_id && entry.session_id == session_context.session_id
    return true if entry.rollout_path && session_context.rollout_path && entry.rollout_path == session_context.rollout_path
    return true if entry.transcript_path && session_context.transcript_path && entry.transcript_path == session_context.transcript_path
    return true if entry.cwd && session_context.cwd && entry.cwd == session_context.cwd

    false
  end

  def apply_pending_scrub(entry)
    config = load_secret_config(entry.config_path)
    replacements = build_scrub_replacements_from_aliases(entry.aliases, config)
    targets_scrubbed = 0
    rollout_path = resolve_rollout_path(entry)
    targets_scrubbed += 1 if rollout_path && scrub_jsonl_file(rollout_path, replacements)

    history_path = codex_history_path
    targets_scrubbed += 1 if history_path.exist? && scrub_history_file(history_path, entry, replacements)
    targets_scrubbed.positive?
  rescue SecretResolutionError
    false
  end

  def resolve_rollout_path(entry)
    [entry.rollout_path, entry.transcript_path].compact.each do |candidate|
      path = Pathname.new(File.expand_path(candidate))
      return path if path.exist?
    end

    state_db = codex_state_db_path
    return nil unless state_db.exist?

    query_specs = []
    query_specs << ["SELECT rollout_path FROM threads WHERE id = ? ORDER BY updated_at_ms DESC LIMIT 1", entry.thread_id] if entry.thread_id
    if entry.session_id && entry.session_id != entry.thread_id
      query_specs << ["SELECT rollout_path FROM threads WHERE id = ? ORDER BY updated_at_ms DESC LIMIT 1", entry.session_id]
    end
    query_specs << ["SELECT rollout_path FROM threads WHERE cwd = ? ORDER BY updated_at_ms DESC LIMIT 1", entry.cwd] if entry.cwd

    sqlite3 = find_executable("sqlite3")
    return nil if sqlite3.nil?

    query_specs.each do |query, parameter|
      sql = query.sub("?", sql_quote(parameter))
      stdout, _stderr, status = Open3.capture3(sqlite3, state_db.to_s, sql)
      next unless status.success?

      value = stdout.lines.first.to_s.strip
      next if value.empty?

      path = Pathname.new(File.expand_path(value))
      return path if path.exist?
    end

    nil
  end

  def sql_quote(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def scrub_jsonl_file(path, replacements)
    return false unless path.exist?

    original_lines = path.read.split("\n", -1)
    updated_lines = []
    changed = false

    original_lines.each do |line|
      if line.empty?
        updated_lines << line
        next
      end

      begin
        payload = JSON.parse(line)
        scrubbed_payload, payload_changed = scrub_json_value(payload, replacements)
        updated_lines << JSON.generate(scrubbed_payload)
        changed ||= payload_changed
      rescue JSON::ParserError
        updated_line, line_changed = scrub_string_value(line, replacements)
        updated_lines << updated_line
        changed ||= line_changed
      end
    end

    path.write(updated_lines.join("\n")) if changed
    changed
  end

  def scrub_history_file(path, entry, replacements)
    original_lines = path.read.split("\n", -1)
    updated_lines = []
    changed = false
    session_keys = [entry.session_id, entry.thread_id].compact
    return false if session_keys.empty?

    original_lines.each do |line|
      if line.empty?
        updated_lines << line
        next
      end

      begin
        payload = JSON.parse(line)
      rescue JSON::ParserError
        updated_lines << line
        next
      end

      target_session = payload["session_id"]
      unless session_keys.include?(target_session)
        updated_lines << line
        next
      end

      scrubbed_payload, payload_changed = scrub_json_value(payload, replacements)
      updated_lines << JSON.generate(scrubbed_payload)
      changed ||= payload_changed
    end

    path.write(updated_lines.join("\n")) if changed
    changed
  end

  def scrub_json_value(value, replacements)
    case value
    when String
      scrub_string_value(value, replacements)
    when Array
      changed = false
      updated_items = value.map do |item|
        updated_item, item_changed = scrub_json_value(item, replacements)
        changed ||= item_changed
        updated_item
      end
      [updated_items, changed]
    when Hash
      changed = false
      updated_hash = {}
      value.each do |key, nested|
        updated_nested, nested_changed = scrub_json_value(nested, replacements)
        updated_hash[key] = updated_nested
        changed ||= nested_changed
      end
      [updated_hash, changed]
    else
      [value, false]
    end
  end

  def scrub_string_value(text, replacements)
    updated = text.dup
    changed = false
    replacements.each do |replacement|
      raw_value = replacement["raw"]
      masked_value = replacement["replacement"]
      next if raw_value.nil? || raw_value.empty? || !updated.include?(raw_value)

      updated = updated.gsub(raw_value, masked_value)
      changed = true
    end
    [updated, changed]
  end

  def optional_str(value)
    return value if value.is_a?(String) && !value.strip.empty?

    nil
  end
end
