#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"

require_relative "../scripts/common"
require_relative "../scripts/install_claude"
require_relative "../scripts/install_codex"
require_relative "../scripts/install_codex_plugin"
require_relative "../scripts/post_tool_use_guard"
require_relative "../scripts/pre_tool_use_guard"
require_relative "../scripts/session_start_context"
require_relative "../scripts/stop_session_scrub"
require_relative "../scripts/uninstall_claude"
require_relative "../scripts/uninstall_codex_plugin"
require_relative "../scripts/user_prompt_submit_guard"

class SessionSecretsTest < Minitest::Test
  def with_env(updates)
    previous = {}
    updates.each do |key, value|
      previous[key] = ENV.key?(key) ? ENV[key] : :__missing__
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  def placeholder(value)
    SessionSecrets.placeholder_wrap(value)
  end

  def fake_github_secret
    "ghp_" + ("A" * 24)
  end

  def fake_openai_secret
    "sk-" + ("B" * 24)
  end

  def write_secret_config(path, defaults: {}, aliases: {})
    path = Pathname.new(path)
    path.dirname.mkpath
    path.write(SessionSecrets.render_secret_config(defaults, aliases))
  end

  def read_json(path)
    JSON.parse(Pathname.new(path).read)
  end

  def build_minimal_source_tree(root)
    root = Pathname.new(root)
    root.join(".codex-plugin").mkpath
    root.join("hooks").mkpath
    root.join("scripts").mkpath
    root.join(".codex-plugin", "plugin.json").write(
      JSON.pretty_generate(
        {
          "name" => InstallCodexPlugin::DEFAULT_PLUGIN_NAME,
          "interface" => { "category" => "Security" }
        }
      ) + "\n"
    )
    root.join("session-secrets.toml.example").write("[defaults]\nimport_backend = \"dotenv\"\n")
    root.join("hooks", "hooks.json").write("{\"hooks\":{}}\n")
    %w[
      user_prompt_submit_guard.rb
      pre_tool_use_guard.rb
      post_tool_use_guard.rb
      stop_session_scrub.rb
      common.rb
      run_with_secrets.sh
    ].each do |name|
      root.join("scripts", name).write("# placeholder\n")
    end
  end

  def test_import_secret_value_writes_dotenv_and_alias_config
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      config = SessionSecrets::SecretConfig.new(
        path: config_path,
        defaults: {
          "import_backend" => "dotenv",
          "default_dotenv_path" => ".env",
          "keychain_service" => "session-secrets-guard"
        },
        aliases: {}
      )

      imported, updated_config = SessionSecrets.import_secret_value(
        fake_github_secret,
        context_text: "github token for tests",
        config: config
      )

      assert_equal "github_token", imported.alias_name
      assert_equal "dotenv", imported.backend
      assert_equal "GITHUB_TOKEN", imported.env_name
      assert_equal ".env", updated_config.aliases["github_token"]["path"]
      assert_includes Pathname.new(tmpdir).join(".env").read, "GITHUB_TOKEN="
      assert config_path.exist?
    end
  end

  def test_user_prompt_submit_allow_and_scrub_queues_pending_scrub
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      config_path = root.join("session-secrets.toml")
      pending_path = root.join("pending_scrubs.json")
      write_secret_config(
        config_path,
        defaults: {
          "import_backend" => "dotenv",
          "prompt_import_mode" => "allow_and_scrub",
          "default_dotenv_path" => ".env"
        }
      )

      prompt = "github token #{placeholder(fake_github_secret)} 넣어둬"
      response = nil
      with_env(
        "SESSION_SECRETS_CONFIG" => config_path.to_s,
        "SESSION_SECRETS_PENDING_SCRUBS" => pending_path.to_s
      ) do
        response = UserPromptSubmitGuard.handle({ "prompt" => prompt, "thread_id" => "thread-1" }, "codex")
      end

      context = response.dig("hookSpecificOutput", "additionalContext")
      assert_includes context, placeholder("github_token")
      assert pending_path.exist?
      queued = read_json(pending_path)
      assert_equal ["github_token"], queued[0]["aliases"]
    end
  end

  def test_copy_masked_prompt_to_clipboard_defaults_to_claude_only
    config = SessionSecrets::SecretConfig.new(path: nil, defaults: {}, aliases: {})
    copied = []

    SessionSecrets.stub(:copy_text_to_clipboard, ->(text) { copied << text; true }) do
      assert_equal true, SessionSecrets.copy_masked_prompt_to_clipboard("safe resend", config, "claude")
      assert_equal false, SessionSecrets.copy_masked_prompt_to_clipboard("safe resend", config, "codex")
    end

    assert_equal ["safe resend"], copied
  end

  def test_prepare_blocked_prompt_resend_falls_back_when_accessibility_denied
    config = SessionSecrets::SecretConfig.new(path: nil, defaults: {}, aliases: {})
    paste_calls = 0

    SessionSecrets.stub(:copy_text_to_clipboard, ->(_text) { true }) do
      SessionSecrets.stub(:accessibility_permission_granted?, false) do
        SessionSecrets.stub(:schedule_clipboard_paste, ->(*) { paste_calls += 1; true }) do
          assert_equal :copied_no_accessibility,
                       SessionSecrets.prepare_blocked_prompt_resend("safe resend", config, "claude")
        end
      end
    end

    assert_equal 0, paste_calls
  end

  def test_prepare_blocked_prompt_resend_schedules_paste_when_accessibility_granted
    config = SessionSecrets::SecretConfig.new(path: nil, defaults: {}, aliases: {})
    paste_calls = 0

    SessionSecrets.stub(:copy_text_to_clipboard, ->(_text) { true }) do
      SessionSecrets.stub(:accessibility_permission_granted?, true) do
        SessionSecrets.stub(:schedule_clipboard_paste, ->(*) { paste_calls += 1; true }) do
          assert_equal :paste_scheduled,
                       SessionSecrets.prepare_blocked_prompt_resend("safe resend", config, "claude")
        end
      end
    end

    assert_equal 1, paste_calls
  end

  def test_build_import_success_message_for_no_accessibility_advises_cmd_v
    imported = [
      SessionSecrets::ImportedSecret.new(
        raw: "ghp_token",
        alias_name: "github_token",
        env_name: "GITHUB_TOKEN",
        backend: "dotenv"
      )
    ]

    message = SessionSecrets.build_import_success_message(
      imported,
      "github token #{SessionSecrets.placeholder_wrap('github_token')}",
      resend_delivery: :copied_no_accessibility
    )

    assert_includes message, "Cmd+V"
    assert_includes message, "Accessibility"
  end

  def test_user_prompt_submit_block_mode_blocks_after_import
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      write_secret_config(
        config_path,
        defaults: {
          "import_backend" => "dotenv",
          "prompt_import_mode" => "block",
          "default_dotenv_path" => ".env"
        }
      )

      response = nil
      with_env("SESSION_SECRETS_CONFIG" => config_path.to_s) do
        SessionSecrets.stub(:prepare_blocked_prompt_resend, :paste_scheduled) do
          response = UserPromptSubmitGuard.handle(
            { "prompt" => "github token #{placeholder(fake_github_secret)} 저장해" },
            "claude"
          )
        end
      end

      assert_equal "block", response["decision"]
      assert_includes response["reason"], placeholder("github_token")
      assert_includes response["reason"], "queued back into the input box"
    end
  end

  def test_user_prompt_submit_claude_runtime_prefers_runtime_specific_block_mode
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      write_secret_config(
        config_path,
        defaults: {
          "import_backend" => "dotenv",
          "prompt_import_mode" => "allow_and_scrub",
          "claude_prompt_import_mode" => "block",
          "default_dotenv_path" => ".env"
        }
      )

      response = nil
      with_env("SESSION_SECRETS_CONFIG" => config_path.to_s) do
        response = UserPromptSubmitGuard.handle(
          { "prompt" => "github token #{placeholder(fake_github_secret)} 저장해" },
          "claude"
        )
      end

      assert_equal "block", response["decision"]
      assert_includes response["reason"], placeholder("github_token")
    end
  end

  def test_user_prompt_submit_plain_secret_blocks_after_import_with_alias_resend
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      write_secret_config(
        config_path,
        defaults: {
          "import_backend" => "dotenv",
          "prompt_import_mode" => "allow_and_scrub",
          "default_dotenv_path" => ".env"
        }
      )

      response = nil
      with_env("SESSION_SECRETS_CONFIG" => config_path.to_s) do
        SessionSecrets.stub(:prepare_blocked_prompt_resend, :paste_scheduled) do
          response = UserPromptSubmitGuard.handle(
            { "prompt" => "github token #{fake_github_secret} 저장해" },
            "claude"
          )
        end
      end

      assert_equal "block", response["decision"]
      assert_includes response["reason"], "detected secret value was blocked"
      assert_includes response["reason"], placeholder("github_token")
      assert_includes response["reason"], "Suggested resend: github token #{placeholder('github_token')} 저장해"
      assert_includes Pathname.new(tmpdir).join(".env").read, "GITHUB_TOKEN="
    end
  end

  def test_pre_tool_use_rewrites_claude_bash_placeholders
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      write_secret_config(
        config_path,
        aliases: {
          "github_token" => {
            "env_name" => "GITHUB_TOKEN",
            "source" => "env",
            "name" => "GITHUB_TOKEN"
          }
        }
      )

      response = nil
      with_env("SESSION_SECRETS_CONFIG" => config_path.to_s) do
        response = PreToolUseGuard.handle(
          {
            "tool_name" => "Bash",
            "tool_input" => { "command" => "echo #{placeholder('github_token')}" }
          },
          "claude"
        )
      end

      command = response.dig("hookSpecificOutput", "updatedInput", "command")
      assert_equal "allow", response.dig("hookSpecificOutput", "permissionDecision")
      assert_includes command, "run_with_secrets.sh"
      assert_includes command, "$GITHUB_TOKEN"
      refute_includes command, placeholder("github_token")
    end
  end

  def test_pre_tool_use_denies_secret_refs_outside_bash
    Dir.mktmpdir do |tmpdir|
      config_path = Pathname.new(tmpdir).join("session-secrets.toml")
      write_secret_config(
        config_path,
        aliases: {
          "github_token" => {
            "env_name" => "GITHUB_TOKEN",
            "source" => "env",
            "name" => "GITHUB_TOKEN"
          }
        }
      )

      response = nil
      with_env("SESSION_SECRETS_CONFIG" => config_path.to_s) do
        response = PreToolUseGuard.handle(
          {
            "tool_name" => "Write",
            "tool_input" => { "content" => placeholder("github_token") }
          },
          "codex"
        )
      end

      assert_equal "deny", response.dig("hookSpecificOutput", "permissionDecision")
    end
  end

  def test_post_tool_use_blocks_secret_like_output
    response = PostToolUseGuard.handle(
      { "tool_response" => { "stdout" => "token=#{fake_openai_secret}" } },
      "codex"
    )

    assert_equal "block", response["decision"]
    assert_includes response["reason"], "Potential secret detected"
  end

  def test_session_start_context_mentions_claude_rewrite
    response = SessionStartContext.handle("claude")
    context = response.dig("hookSpecificOutput", "additionalContext")

    assert_includes context, "rewritten into safe env injection"
  end

  def test_install_codex_merge_replaces_old_managed_hook_commands
    existing = {
      "hooks" => {
        "Notification" => [
          {
            "hooks" => [
              { "type" => "command", "command" => "/bin/echo keep" }
            ]
          }
        ],
        "UserPromptSubmit" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => "env SESSION_SECRETS_CONFIG=/tmp/a /old/scripts/user_prompt_submit_guard.py --runtime codex"
              }
            ]
          }
        ]
      }
    }

    desired = InstallCodex.build_hooks_config("/new", Pathname.new("/usr/bin/ruby"), Pathname.new("/tmp/a"))
    merged = InstallCodex.merge_hooks(existing, desired)
    command = InstallCodex.extract_first_command(merged["hooks"]["UserPromptSubmit"][0])

    assert_includes command, "/new/scripts/user_prompt_submit_guard.rb"
    refute_includes command, "/old/scripts/user_prompt_submit_guard.py"
    assert_equal "/bin/echo keep", InstallCodex.extract_first_command(merged["hooks"]["Notification"][0])
  end

  def test_install_codex_end_to_end
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      repo_root = root.join("repo")
      codex_home = root.join(".codex")
      repo_root.mkpath
      repo_root.join("scripts").mkpath
      repo_root.join("session-secrets.toml.example").write("[defaults]\nimport_backend = \"dotenv\"\n")

      results = InstallCodex.install(codex_home, repo_root)

      hooks = read_json(codex_home.join("hooks.json"))
      command = InstallCodex.extract_first_command(hooks["hooks"]["UserPromptSubmit"][0])
      assert_equal "/usr/bin/ruby", results["runtime_path"]
      assert_includes command, "/usr/bin/ruby"
      assert_includes command, "user_prompt_submit_guard.rb"
      assert_match(/\bhooks = true\b/, codex_home.join("config.toml").read)
      assert repo_root.join("session-secrets.toml").exist?
    end
  end

  def test_install_codex_plugin_end_to_end
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      source_root = root.join("source")
      codex_home = root.join(".codex")
      marketplace_path = root.join(".agents", "plugins", "marketplace.json")
      plugin_root = codex_home.join("plugins", InstallCodexPlugin::DEFAULT_PLUGIN_NAME)
      state_dir = root.join(".session-secrets-guard")

      build_minimal_source_tree(source_root)
      results = InstallCodexPlugin.install_plugin(source_root, codex_home, marketplace_path, plugin_root, state_dir)

      plugin_hooks = read_json(plugin_root.join("hooks", "hooks.json"))
      command = InstallCodex.extract_first_command(plugin_hooks["hooks"]["UserPromptSubmit"][0])
      marketplace = read_json(marketplace_path)

      assert results["plugin_staged"]
      assert results["state_config_created"]
      assert_equal "/usr/bin/ruby", results["runtime_path"]
      assert_includes command, plugin_root.join("scripts", "user_prompt_submit_guard.rb").to_s
      assert_equal InstallCodexPlugin::DEFAULT_PLUGIN_NAME, marketplace["plugins"][0]["name"]
    end
  end

  def test_install_claude_writes_settings
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      repo_root = root.join("repo")
      claude_home = root.join(".claude")
      state_dir = root.join(".session-secrets-guard-claude")
      repo_root.mkpath
      repo_root.join("session-secrets.toml.example").write("[defaults]\nimport_backend = \"dotenv\"\n")

      results = InstallClaude.install_claude(repo_root, claude_home, state_dir)

      settings = read_json(claude_home.join("settings.json"))
      command = InstallCodex.extract_first_command(settings["hooks"]["UserPromptSubmit"][0])
      state_config = state_dir.join("session-secrets.toml").read
      refute settings["hooks"].key?("Stop")
      assert_equal "/usr/bin/ruby", results["runtime_path"]
      assert results["state_defaults_updated"]
      assert_includes command, "user_prompt_submit_guard.rb"
      assert_equal "Bash|Edit|Write", settings["hooks"]["PreToolUse"][0]["matcher"]
      assert_includes state_config, "claude_prompt_import_mode = \"block\""
    end
  end

  def test_uninstall_codex_plugin_removes_managed_files_and_hooks
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      codex_home = root.join(".codex")
      plugin_root = codex_home.join("plugins", InstallCodexPlugin::DEFAULT_PLUGIN_NAME)
      cache_root = codex_home.join("plugins", "cache", "personal-local", InstallCodexPlugin::DEFAULT_PLUGIN_NAME)
      marketplace_path = root.join(".agents", "plugins", "marketplace.json")
      state_dir = root.join(".session-secrets-guard")
      plugin_root.mkpath
      cache_root.mkpath
      state_dir.mkpath

      codex_home.join("hooks.json").dirname.mkpath
      codex_home.join("hooks.json").write(
        JSON.pretty_generate(
          {
            "hooks" => {
              "UserPromptSubmit" => [
                {
                  "hooks" => [
                    {
                      "type" => "command",
                      "command" => "/usr/bin/ruby #{plugin_root.join('scripts', 'user_prompt_submit_guard.rb')} --runtime codex"
                    }
                  ]
                }
              ]
            }
          }
        ) + "\n"
      )
      marketplace_path.dirname.mkpath
      marketplace_path.write(
        JSON.pretty_generate(
          {
            "plugins" => [
              { "name" => InstallCodexPlugin::DEFAULT_PLUGIN_NAME },
              { "name" => "keep-me" }
            ]
          }
        ) + "\n"
      )

      results = UninstallCodexPlugin.uninstall_plugin(
        codex_home,
        marketplace_path,
        plugin_root,
        state_dir,
        purge_state: false,
        purge_keychain: false
      )

      refute plugin_root.exist?
      refute cache_root.exist?
      assert results["marketplace_updated"]
      refute results["state_removed"]
      rendered_marketplace = read_json(marketplace_path)
      assert_equal ["keep-me"], rendered_marketplace["plugins"].map { |entry| entry["name"] }
    end
  end

  def test_uninstall_claude_removes_managed_hooks_and_keeps_other_settings
    Dir.mktmpdir do |tmpdir|
      claude_home = Pathname.new(tmpdir).join(".claude")
      settings_path = claude_home.join("settings.json")
      settings_path.dirname.mkpath
      settings_path.write(
        JSON.pretty_generate(
          {
            "$schema" => "https://json.schemastore.org/claude-code-settings.json",
            "theme" => "keep",
            "hooks" => {
              "PreToolUse" => [
                {
                  "hooks" => [
                    {
                      "type" => "command",
                      "command" => "/usr/bin/ruby /x/scripts/pre_tool_use_guard.rb --runtime claude"
                    }
                  ]
                }
              ],
              "Notification" => [
                {
                  "hooks" => [
                    { "type" => "command", "command" => "/bin/echo keep" }
                  ]
                }
              ]
            }
          }
        ) + "\n"
      )

      results = UninstallClaude.uninstall_claude(claude_home, Pathname.new(tmpdir).join(".session-secrets-guard-claude"), purge_state: false, purge_keychain: false)

      rendered = read_json(settings_path)
      assert results["settings_updated"]
      assert_equal "keep", rendered["theme"]
      assert_equal "/bin/echo keep", InstallCodex.extract_first_command(rendered["hooks"]["Notification"][0])
      refute rendered["hooks"].key?("PreToolUse")
    end
  end

  def test_drain_pending_scrub_rewrites_rollout_and_history
    Dir.mktmpdir do |tmpdir|
      root = Pathname.new(tmpdir)
      config_path = root.join("session-secrets.toml")
      rollout_path = root.join("rollout.jsonl")
      codex_home = root.join(".codex")
      history_path = codex_home.join("history.jsonl")
      pending_path = codex_home.join("pending_scrubs.json")
      raw_secret = "value-" + ("C" * 16)
      alias_name = "github_token"

      write_secret_config(
        config_path,
        aliases: {
          alias_name => {
            "env_name" => "GITHUB_TOKEN",
            "source" => "env",
            "name" => "GITHUB_TOKEN"
          }
        }
      )

      rollout_path.write(JSON.generate({ "message" => raw_secret }) + "\n")
      history_path.dirname.mkpath
      history_path.write(JSON.generate({ "session_id" => "session-1", "message" => raw_secret }) + "\n")

      with_env(
        "SESSION_SECRETS_PENDING_SCRUBS" => pending_path.to_s,
        "SESSION_SECRETS_CONFIG" => config_path.to_s,
        "CODEX_HOME" => codex_home.to_s,
        "GITHUB_TOKEN" => raw_secret
      ) do
        SessionSecrets.queue_pending_scrub(
          SessionSecrets::SessionContext.new(session_id: "session-1", rollout_path: rollout_path.to_s),
          [SessionSecrets::ImportedSecret.new(alias_name: alias_name)],
          SessionSecrets.load_secret_config(config_path)
        )
        StopSessionScrub.handle({ "session_id" => "session-1" })
      end

      assert_includes rollout_path.read, placeholder(alias_name)
      assert_includes history_path.read, placeholder(alias_name)
      refute pending_path.exist? && !read_json(pending_path).empty?
    end
  end
end
