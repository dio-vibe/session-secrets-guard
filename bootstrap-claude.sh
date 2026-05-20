#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${SESSION_SECRETS_GUARD_REPO:-dio-vibe/session-secrets-guard}"
REPO_REF="${SESSION_SECRETS_GUARD_REF:-main}"
ARCHIVE_URL="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}"
GIT_URL="https://github.com/${REPO_SLUG}.git"

INSTALL_DIR="${SESSION_SECRETS_GUARD_CLAUDE_REPO_DIR:-$HOME/.session-secrets-guard-claude/repo}"
mkdir -p "$(dirname "$INSTALL_DIR")"

if command -v git >/dev/null 2>&1; then
  rm -rf "$INSTALL_DIR"
  git clone --depth=1 --branch "$REPO_REF" "$GIT_URL" "$INSTALL_DIR" >/dev/null 2>&1
else
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  archive_path="$tmpdir/repo.tar.gz"
  curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
  tar -xzf "$archive_path" -C "$tmpdir"
  extracted_dir="$tmpdir/$(basename "$REPO_SLUG")-$REPO_REF"
  if [[ ! -d "$extracted_dir" ]]; then
    extracted_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  fi
  rm -rf "$INSTALL_DIR"
  mv "$extracted_dir" "$INSTALL_DIR"
fi

exec "$INSTALL_DIR/install-claude.sh" "$@"
