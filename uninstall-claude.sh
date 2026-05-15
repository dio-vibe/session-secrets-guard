#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUBY_BIN="/usr/bin/ruby"

if [[ ! -x "$RUBY_BIN" ]]; then
  echo "System Ruby was not found at $RUBY_BIN." >&2
  exit 1
fi

exec "$RUBY_BIN" "$ROOT_DIR/scripts/uninstall_claude.rb" "$@"
