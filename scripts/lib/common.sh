#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[node2] %s\n' "$*"; }
die() { printf '[node2] ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
load_env() {
  local file=${NODE2_ENV_FILE:-.env}
  local name
  local -A overrides=()
  for name in NODE2_HOST NODE2_USER NODE2_SSH_KEY NODE2_DOMAIN LETSENCRYPT_EMAIL NODE2_WEB_ROOT BACKUP_ROOT DEPLOY_CONFIRM; do
    [[ -v $name ]] && overrides[$name]=${!name}
  done
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
  for name in "${!overrides[@]}"; do
    printf -v "$name" '%s' "${overrides[$name]}"
    export "$name"
  done
}
ssh_target() {
  local host=${1:?host required}
  [[ "$host" == *@* ]] && { printf '%s' "$host"; return; }
  printf '%s@%s' "${NODE2_USER:-root}" "$host"
}
confirm_write() { [[ ${DEPLOY_CONFIRM:-NO} == YES ]] || die 'write action requires DEPLOY_CONFIRM=YES'; }
ssh() {
  local -a key_args=()
  [[ -n ${NODE2_SSH_KEY:-} ]] && key_args=(-i "$NODE2_SSH_KEY")
  command ssh "${key_args[@]}" "$@"
}
scp() {
  local -a key_args=()
  [[ -n ${NODE2_SSH_KEY:-} ]] && key_args=(-i "$NODE2_SSH_KEY")
  command scp "${key_args[@]}" "$@"
}
