#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${SESSION_SECRETS_GUARD_REPO:-dio-vibe/session-secrets-guard}"
REPO_REF="${SESSION_SECRETS_GUARD_REF:-main}"
ARCHIVE_URL="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}"
GIT_URL="https://github.com/${REPO_SLUG}.git"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

checkout_dir="$tmpdir/repo"

if command -v git >/dev/null 2>&1; then
  git clone --depth=1 --branch "$REPO_REF" "$GIT_URL" "$checkout_dir" >/dev/null 2>&1
else
  archive_path="$tmpdir/repo.tar.gz"
  curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
  mkdir -p "$checkout_dir"
  tar -xzf "$archive_path" -C "$tmpdir"
  extracted_dir="$tmpdir/$(basename "$REPO_SLUG")-$REPO_REF"
  if [[ ! -d "$extracted_dir" ]]; then
    extracted_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  fi
  mv "$extracted_dir" "$checkout_dir"
fi

exec "$checkout_dir/uninstall-claude.sh" "$@"
