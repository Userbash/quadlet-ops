#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[node2] %s\n' "$*"; }
die() { printf '[node2] ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
load_env() {
  local file=${NODE2_ENV_FILE:-.env}
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}
ssh_target() {
  local host=${1:?host required}
  [[ "$host" == *@* ]] && { printf '%s' "$host"; return; }
  printf '%s@%s' "${NODE2_USER:-root}" "$host"
}
confirm_write() { [[ ${DEPLOY_CONFIRM:-NO} == YES ]] || die 'write action requires DEPLOY_CONFIRM=YES'; }
