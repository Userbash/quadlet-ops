#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
need_cmd ssh
shopt -s nullglob
units=("$(dirname "$0")/../deploy/"*.container)
(( ${#units[@]} > 0 )) || die 'no Quadlet container definitions found in deploy/'

for unit in "${units[@]}"; do
  unit_name=$(basename "$unit" .container)
  "$(dirname "$0")/deploy-node2.sh" "$target" "$unit_name"
done

service_uid=$(ssh -o BatchMode=yes "$target" 'id -u doom')
runtime_dir="/run/user/$service_uid"
for unit in "${units[@]}"; do
  unit_name=$(basename "$unit" .container)
  ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active --quiet '$unit_name.service'"
done
printf 'All Quadlet container services are active on %s.\n' "$target"
