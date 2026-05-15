#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: run_with_secrets.sh --set ENV_NAME=SPEC [--set ENV_NAME=SPEC ...] -- command [args...]
EOF
  exit 2
}

die() {
  echo "run_with_secrets: $*" >&2
  exit 2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

decode_base64() {
  local encoded="$1"
  if printf '' | base64 --decode >/dev/null 2>&1; then
    printf '%s' "$encoded" | base64 --decode
    return
  fi
  printf '%s' "$encoded" | base64 -D
}

resolve_dotenv() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || die "dotenv file \`$path\` does not exist."

  local raw_line line current_key current_value
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(trim "$raw_line")"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue

    current_key="$(trim "${line%%=*}")"
    current_value="$(trim "${line#*=}")"
    [[ "$current_key" == "$key" ]] || continue

    if [[ ${#current_value} -ge 2 && "${current_value:0:1}" == '"' && "${current_value: -1}" == '"' ]]; then
      current_value="${current_value:1:${#current_value}-2}"
      current_value="${current_value//\\\\/\\}"
      current_value="${current_value//\\\"/\"}"
      printf '%s' "$current_value"
      return 0
    fi

    if [[ ${#current_value} -ge 2 && "${current_value:0:1}" == "'" && "${current_value: -1}" == "'" ]]; then
      printf '%s' "${current_value:1:${#current_value}-2}"
      return 0
    fi

    current_value="${current_value%% \#*}"
    printf '%s' "$(trim "$current_value")"
    return 0
  done < "$path"

  die "\`$key\` was not found in \`$path\`."
}

resolve_keychain() {
  local service="$1"
  local account="$2"
  if [[ -n "$account" ]]; then
    security find-generic-password -s "$service" -a "$account" -w
    return
  fi
  security find-generic-password -s "$service" -w
}

resolve_spec() {
  local spec="$1"
  local source="${spec%%:*}"
  local remainder="${spec#*:}"

  if [[ "$spec" != *:* ]]; then
    die "unsupported secret source: $spec"
  fi

  case "$source" in
    env)
      [[ -n "$remainder" ]] || die "\`env:\` references must include an environment variable name."
      [[ -n "${!remainder:-}" ]] || die "environment variable \`$remainder\` is not set."
      printf '%s' "${!remainder}"
      ;;
    dotenv)
      [[ "$remainder" == *"#"* ]] || die "\`dotenv:\` references must include path#KEY."
      resolve_dotenv "${remainder%%\#*}" "${remainder#*#}"
      ;;
    keychain)
      local service="${remainder%%/*}"
      local account=""
      if [[ "$remainder" == */* ]]; then
        account="${remainder#*/}"
      fi
      [[ -n "$service" ]] || die "\`keychain:\` references must include a service name."
      resolve_keychain "$service" "$account"
      ;;
    op)
      [[ -n "$remainder" ]] || die "\`op:\` references must include a secret ref."
      op read "$remainder"
      ;;
    vault)
      [[ "$remainder" == *"#"* && "$remainder" == */* ]] || die "\`vault:\` references must include mount/path#field."
      local path_and_field="${remainder}"
      local field="${path_and_field#*#}"
      local mount_and_path="${path_and_field%%\#*}"
      local mount="${mount_and_path%%/*}"
      local secret_path="${mount_and_path#*/}"
      vault kv get "-mount=$mount" "-field=$field" "$secret_path"
      ;;
    command-b64)
      local decoded_command
      decoded_command="$(decode_base64 "$remainder")" || die "failed to decode command backend payload."
      bash -lc "$decoded_command"
      ;;
    *)
      die "unsupported secret source: $source"
      ;;
  esac
}

sets=()
while (($#)); do
  case "$1" in
    --set)
      (($# >= 2)) || usage
      sets+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

((${#sets[@]} > 0)) || die "at least one --set ENV_NAME=SPEC is required."
(($# > 0)) || die "missing command after --"

for assignment in "${sets[@]}"; do
  [[ "$assignment" == *=* ]] || die "invalid --set value: $assignment"
  env_name="${assignment%%=*}"
  spec="${assignment#*=}"
  [[ -n "$env_name" && -n "$spec" ]] || die "invalid --set value: $assignment"
  value="$(resolve_spec "$spec")"
  printf -v "$env_name" '%s' "$value"
  export "$env_name"
done

exec "$@"
