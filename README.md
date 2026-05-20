# Session Secrets Guard

`session-secrets-guard` lets coding-agent users paste a raw `[[secret]]` once,
store it locally, and keep using a generated alias such as `[[github_token]]`
without repeating the raw value in chat.

This project is for:

- Codex hooks
- Claude Code hooks
- local backends such as macOS Keychain and `.env`
- optional read-through backends such as `env`, 1Password, Vault, and local commands

It is not a vault and it is not a replacement for Keychain, 1Password, or Vault.

## What it does

It handles two jobs:

1. Import raw `[[secret]]` chat placeholders into a local backend.
2. Teach the agent to keep using aliases and backend locations instead of raw values.

## User model

The intended user model is simple:

1. You paste a raw secret once:

```text
이거 github 토큰이야 [[ghp_example_not_real_1234567890]] 로 확인해줘
```

2. The hook stores it locally and creates an alias:

- `[[github_token]]`
- `[[linear_api_key]]`
- `[[database_password]]`

3. Later turns should use the alias, not the raw value:

```text
방금 저장한 [[github_token]] 으로 다시 확인해줘
```

4. The agent should resolve that alias from its configured backend:

- Keychain-backed alias -> macOS `security`
- dotenv-backed alias -> configured `.env` file
- env-backed alias -> current environment variable

Most users should not need to know about any internal helper script.

## Example flow

Minimal Codex or Claude flow:

```text
User:
이거 github 토큰이야 [\[raw-chat-secret\]] 로 확인해줘

Hook:
#1 -> [\[github_token\]] stored at keychain(service=session-secrets-guard, account=github_token)

Later user turn:
방금 저장한 [\[github_token\]] 으로 다시 확인해줘

Agent:
resolve [\[github_token\]] from keychain(service=session-secrets-guard, account=github_token)
```

The important part is the shape:

- raw chat placeholder on the first turn
- generated alias plus backend location after import
- alias reuse on later turns

## What the agent sees

After import, the hook tells the agent where the alias lives. For example:

- `[[account_password]] stored at keychain(service=session-secrets-guard, account=account_password)`
- `[[openai_api_key]] stored at dotenv(path=.env, key=OPENAI_API_KEY)`

That keeps the model focused on:

- alias names
- backend locations
- avoiding raw secret output

## Runtime behavior

### Codex

Codex can:

- import raw `[[secret]]` chat placeholders
- attach alias and backend guidance to the active turn
- queue a local scrub of `~/.codex/sessions/...jsonl` and `~/.codex/history.jsonl`
- block dangerous tool input and leaked tool output

Default behavior for Codex is:

```toml
[defaults]
prompt_import_mode = "allow_and_scrub"
```

That means:

1. the current turn can continue
2. the raw placeholder may still be visible to the model in that turn
3. local resume history is rewritten later to use aliases

If you want stricter behavior where the raw value never reaches the model, use:

```toml
[defaults]
prompt_import_mode = "block"
```

### Claude Code

Claude Code can do the stricter import-and-block flow, and it can also rewrite
Bash tool input through `PreToolUse.updatedInput`.

## Supported backends

### Import backends

Raw `[[secret]]` imports support:

- `auto`
- `keychain`
- `dotenv`

`auto` chooses:

- macOS Keychain when `security` is available
- `.env` otherwise

### Read backends

Alias resolution supports:

- `env`
- `dotenv`
- `keychain`
- `op`
- `vault`
- `command`

The split is intentional:

- import backends store new raw chat secrets
- read backends describe where aliases should be resolved later

## Quick start

### Codex

Install:

```bash
./install-plugin.sh
```

Or bootstrap from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap.sh | bash
```

That bootstrap path writes:

- `~/.codex/plugins/session-secrets-guard`
- `~/.session-secrets-guard/session-secrets.toml`
- `~/.agents/plugins/marketplace.json`
- and, on current Codex builds, active fallback hooks in `~/.codex/hooks.json`

Then:

1. Restart Codex.
2. Open `/hooks`.
3. Review the 4 `Session Secrets Guard` hooks once.
4. Start a fresh session.

Recommended defaults:

- leave `import_backend = "auto"`
- use `prompt_import_mode = "allow_and_scrub"` for smoother UX
- switch to `block` if you want stricter no-exposure behavior

Advanced Codex path:

```bash
./install.sh
```

That path skips the staged plugin flow and writes active hooks directly into
the current machine's `~/.codex/hooks.json` using this repo checkout as the
runtime location. It is useful for development and debugging, but the plugin
install path above is the recommended end-user path.

### Claude Code

Preferred path:

```bash
./install-claude.sh
```

Or bootstrap from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap-claude.sh | bash
```

The bootstrap script clones the repo into
`~/.session-secrets-guard-claude/repo` (override with
`SESSION_SECRETS_GUARD_CLAUDE_REPO_DIR`) and then runs `install-claude.sh` from
there, so the absolute hook paths it bakes into `~/.claude/settings.json` keep
resolving after the bootstrap process exits.

That installer:

- uses macOS system Ruby at `/usr/bin/ruby`
- creates `~/.session-secrets-guard-claude/session-secrets.toml` if missing
- sets `claude_prompt_import_mode = "block"` unless you already overrode it
- copies alias-only resend prompts to the clipboard and tries to paste them back into the input box on raw-placeholder blocks
- merges absolute-path hook commands into `~/.claude/settings.json`

The checked-in [`examples/claude/settings.json`](examples/claude/settings.json)
is only a template. It uses relative paths and is not the recommended install
path for general users.

If you do not want that macOS clipboard/paste assist, set either
`claude_copy_resend_to_clipboard = false` or
`claude_prefill_resend_prompt = false` in your state config.

## Removal

Standard removal:

```bash
./uninstall-plugin.sh
```

Or from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap-uninstall.sh | bash
```

That removes:

- the staged plugin copy
- the personal-local cache copy
- the marketplace entry
- the active global hook fallback

It preserves local state and Keychain items by default.

Claude-only removal:

```bash
./uninstall-claude.sh
```

Or from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap-uninstall-claude.sh | bash
```

That removes this repo's managed hook entries from `~/.claude/settings.json`
and preserves local state and Keychain items by default.

Full wipe:

```bash
./uninstall-plugin.sh --purge-state --purge-keychain
./uninstall-claude.sh --purge-state --purge-keychain
```

The same flags also work through the GitHub bootstraps:

```bash
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap-uninstall.sh | bash -s -- --purge-state --purge-keychain
curl -fsSL https://raw.githubusercontent.com/dio-vibe/session-secrets-guard/main/bootstrap-uninstall-claude.sh | bash -s -- --purge-state --purge-keychain
```

## Config

The config file has two roles:

- import defaults
- alias registry

Example:

```toml
[defaults]
import_backend = "auto"
prompt_import_mode = "allow_and_scrub"
default_dotenv_path = ".env"
keychain_service = "session-secrets-guard"

[aliases.github_token]
env_name = "GITHUB_TOKEN"
source = "env"
name = "GITHUB_TOKEN"

[aliases.openai_api_key]
env_name = "OPENAI_API_KEY"
source = "dotenv"
path = ".env"
key = "OPENAI_API_KEY"
```

When a raw secret is imported, the hook updates this registry automatically.

## Detection and naming

The importer does not need to inspect the raw secret value to pick a name.
It uses masked surrounding prompt context instead.

Examples:

- `github`, `깃허브`, `gh` -> `github_token`
- `linear`, `리니어` -> `linear_api_key`
- `db`, `postgres`, `비밀번호` -> `database_password`
- unknown context -> `session_secret`

If a name is already taken, the importer appends `_2`, `_3`, and so on.

## Known limitations

- Codex currently cannot rewrite Bash tool input through hooks the way Claude can.
- On the current Codex build, `plugin_hooks` is still disabled, so the installer also writes active fallback hooks to `~/.codex/hooks.json`.
- `/hooks` review is still a manual Codex security gate.
- Keychain, 1Password, and Vault integrations are environment-dependent and not equally verified on every machine.
- `allow_and_scrub` improves UX, but it is not the same as strict non-exposure.
- Alias hinting is currently optimized for English and Korean prompt context.

## Validation

Local checks:

```bash
ruby tests/test_secret_guard.rb
ruby -c scripts/*.rb tests/test_secret_guard.rb
```

Current automated coverage includes:

- raw `[[secret]]` import parsing
- alias naming
- `.env` import storage
- `command` backend resolution
- Codex and Claude hook behavior
- installer and uninstall paths
- local history scrub behavior

CI should run these checks on macOS with system Ruby.

## Internal implementation notes

This repo still includes an internal runtime helper around secret resolution and
command execution. It exists because some runtime paths need a consistent way
to resolve aliases and inject values into child processes.

That helper is an implementation detail, not the intended primary user
interface.

## Repository layout

- [`.codex-plugin/plugin.json`](.codex-plugin/plugin.json)
  Codex plugin metadata
- [`hooks/hooks.json`](hooks/hooks.json)
  Codex hook config
- [`examples/claude/settings.json`](examples/claude/settings.json)
  Claude Code hook config template
- [`install-claude.sh`](install-claude.sh)
  Claude Code installer with absolute hook paths
- [`uninstall-claude.sh`](uninstall-claude.sh)
  Claude Code uninstall helper for managed hooks
- [`bootstrap.sh`](bootstrap.sh)
  One-shot Codex installer from GitHub
- [`bootstrap-claude.sh`](bootstrap-claude.sh)
  One-shot Claude installer from GitHub
- [`bootstrap-uninstall.sh`](bootstrap-uninstall.sh)
  One-shot Codex uninstall helper from GitHub
- [`bootstrap-uninstall-claude.sh`](bootstrap-uninstall-claude.sh)
  One-shot Claude uninstall helper from GitHub
- [`session-secrets.toml.example`](session-secrets.toml.example)
  Example defaults and alias config
- [`scripts/`](scripts)
  Hook handlers, installers, internal helpers, and scrub logic
- [`tests/`](tests)
  Unit tests

## Status

This is a useful early-stage open-source utility.

Strong today:

- raw secret import flow
- alias registry updates
- `.env` backend coverage
- install and uninstall automation
- macOS system Ruby compatibility without third-party runtime dependencies

Still rough:

- Codex runtime limitations
- build-specific install caveats
- environment-dependent secret backends
- some implementation details are still more visible than ideal

## See also

- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`SECURITY.md`](SECURITY.md)
