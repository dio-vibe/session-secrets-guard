# Contributing

## Scope

This project is for safe secret handling around coding agents. It is not a
general-purpose vault or a replacement for 1Password, Vault, Keychain, or
platform secret stores.

Good contributions:

- safer hook behavior
- better false-positive and false-negative tuning
- more reliable install paths for Codex and Claude Code
- tests for non-secret sample values
- docs for supported local secret backends

Out of scope:

- features that require storing real secrets in the repo
- test fixtures that contain live credentials
- platform changes that bypass the underlying secret manager's own security

## Local setup

```bash
./install.sh
./install-claude.sh
./uninstall-claude.sh
/usr/bin/ruby tests/test_secret_guard.rb
/usr/bin/ruby -c scripts/*.rb tests/test_secret_guard.rb
bash -n scripts/run_with_secrets.sh install*.sh uninstall*.sh
```

## Test rules

- Never commit real credentials, even revoked ones.
- Use obviously fake sample tokens in tests and docs.
- Prefer `.env` and `command` backends in automated tests.
- Treat Keychain, 1Password, and Vault integrations as environment-dependent.

## Pull requests

- Keep changes small and reviewable.
- Update `README.md` when user-visible behavior changes.
- Add or extend tests when parser, detection, or resolver behavior changes.
- Explain any new detection heuristics and expected tradeoffs.
