---
name: session-secret-usage
description: Import raw `[[secret]]` chat placeholders into local aliases and keep agents on safe secret-handling paths.
---

# Session Secret Usage

Use this plugin when Codex should avoid raw credential handling in normal chat
and tool output, or when a task needs a secret from a supported local source.

Rules:

- Never print or restate secret values.
- Never write raw secrets into code, comments, patches, commits, or logs.
- Prefer existing local environment variables or an approved secret manager.
- A raw `[[secret]]` placeholder should be treated as an import request, not as
  safe prompt content to forward to the model.
- After import, prefer the generated alias such as `[[github_token]]` over
  repeating the raw value.
- In Codex default `allow_and_scrub` mode, the current turn may continue after
  import, but future local session history should be scrubbed back to aliases.
- If a shell command needs a secret, resolve the alias from its configured
  backend first.
  Keychain-backed aliases should be read with macOS `security`, and
  dotenv-backed aliases should be read from the configured dotenv file.
- Inline refs like `[[github_token]]` or `[[env:GITHUB_TOKEN]]` are acceptable
  in prompts; raw token literals are not.
- If a credential is needed but not already available safely, stop and ask for
  a safer path instead of requesting a raw token in chat.
- If a tool output appears to contain a secret, treat it as contaminated output
  and replace it with a safer rerun.

Current runtime limitation:

- Codex can block and add context, but it cannot yet rewrite Bash tool input.
- Claude can rewrite Bash tool input through `PreToolUse.updatedInput`.
