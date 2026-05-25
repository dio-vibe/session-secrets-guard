# Scripts

These scripts are invoked by Codex hooks through `hooks/hooks.json`.

The checked-in hook templates call `/usr/bin/ruby` directly. Installers do not
create a project runtime anymore.

- `common.rb`
  - shared detection, config parsing, resolver, import, scrub, and command rewrite helpers
- `run_with_secrets.sh`
  - dependency-free bash helper used by Claude Bash rewrites to resolve backend refs and exec with injected env vars
- `mask_env_file.rb`
  - prints `.env`-style files with values replaced by length and fingerprint; `--show-fragments` also shows short first/last fragments
- `install_codex.rb`
  - one-command Codex installer that updates `~/.codex/config.toml` and `~/.codex/hooks.json`
- `install_codex_plugin.rb`
  - stages the plugin under `~/.codex/plugins/`, writes a personal marketplace entry, and rewrites staged hook commands
- `install_claude.rb`
  - merges absolute-path hook commands into `~/.claude/settings.json` and creates a per-user state dir
- `uninstall_claude.rb`
  - removes this repo's managed Claude hook entries and optionally purges Claude-side local state
- `session_start_context.rb`
  - optional helper for injecting secret-safe developer context on startup and resume; not installed by default
- `user_prompt_submit_guard.rb`
  - imports raw placeholders, then either blocks or queues a Codex history scrub
- `pre_tool_use_guard.rb`
  - blocks unsafe tool inputs and rewrites Bash placeholders for Claude
- `post_tool_use_guard.rb`
  - blocks tool outputs that appear to leak secrets and opportunistically drains pending scrubs
- `stop_session_scrub.rb`
  - drains queued Codex history scrubs when a turn stops

All Ruby scripts use only the macOS system Ruby standard library.

The intended user-facing model is:

- import a raw `[[secret]]`
- get an alias
- resolve that alias from its configured backend

Supported secret sources:

- `env`
- `dotenv`
- macOS Keychain through `security`
- 1Password through `op read`
- HashiCorp Vault through `vault kv get`
- arbitrary local `command` aliases
