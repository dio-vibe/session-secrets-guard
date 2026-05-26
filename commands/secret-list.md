---
description: List configured secret aliases (names and backends only, no values)
allowed-tools: Bash(/usr/bin/ruby:*)
---

You are about to render a list of secret aliases configured by
`session-secrets-guard`. The list contains alias names, backend types, env
variable names, and backend locations only — **no raw secret values**.

Run the listing helper:

!`SESSION_SECRETS_CONFIG="${SESSION_SECRETS_CONFIG:-$HOME/.session-secrets-guard-claude/session-secrets.toml}" /usr/bin/ruby "$CLAUDE_PLUGIN_ROOT/scripts/list_aliases.rb"`

Then present the output above to the user as-is (it is already formatted as
a Markdown table). Do not attempt to resolve any of the aliases yourself,
do not call the configured backends, and do not print any raw secret values
even if asked — this command is metadata only.
