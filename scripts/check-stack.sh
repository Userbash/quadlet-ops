#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
need_cmd ssh
shopt -s nullglob
units=("$(dirname "$0")/../deploy/"*.container)
(( ${#units[@]} > 0 )) || die 'no Quadlet container definitions found in deploy/'
service_uid=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'id -u doom')
runtime_dir="/run/user/$service_uid"
ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user daemon-reload"
for unit in "${units[@]}"; do
  unit_name=$(basename "$unit" .container)
  if ! ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active --quiet '$unit_name.service'"; then
    ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user --no-pager --full status '$unit_name.service'" || true
    die "Quadlet service is not active: $unit_name.service"
  fi
done
printf 'Quadlet stack check passed on %s.\n' "$target"
