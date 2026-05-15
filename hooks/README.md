# Hooks

This plugin keeps lifecycle config in [hooks.json](./hooks.json).

Current runtime notes:

- `UserPromptSubmit` can import raw `[[secret]]` placeholders into local storage,
  then either block the current prompt or let it continue while queueing a
  local Codex history scrub.
- After import, the user or agent should continue with generated aliases such
  as `[[github_token]]`.
- `PreToolUse` can deny supported tool calls before they run.
- Claude can rewrite Bash tool input through `updatedInput`.
- Codex currently cannot rewrite Bash tool input through hooks, so the agent
  should resolve aliases from their configured backends before running shell
  commands.
- `PostToolUse` can replace tool output with feedback after a tool already ran.
- `Stop` can drain queued Codex history scrubs after a turn completes.

The handlers live in `../scripts/`.

When installed through the personal marketplace flow, the staged plugin copy
gets this file rewritten with absolute commands into `~/.codex/plugins/...`.
The checked-in template calls `/usr/bin/ruby` directly.
