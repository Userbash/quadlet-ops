#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
profile=${2:-node2-full}
profile_file="$(dirname "$0")/../deploy/profiles/$profile.units"
[[ -f $profile_file ]] || die "unknown deployment profile: $profile"
confirm_write
need_cmd ssh

while IFS= read -r service; do
  service=${service%%#*}
  service=${service//[[:space:]]/}
  [[ -n $service ]] || continue
  if [[ $service == dns-stats && -z ${NODE2_TECHNITIUM_API_TOKEN:-} ]]; then continue; fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "test -f /home/doom/.config/containers/systemd/$service.container || test -f /home/doom/.config/containers/systemd/$service.kube" || continue
  ssh "$target" "uid=\$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$uid/bus systemctl --user start '$service.service'"
done < "$profile_file"

ssh "$target" 'nginx -t && fail2ban-client ping && systemctl reload nginx && systemctl restart fail2ban'
printf 'Installed Node2 profile %s activated on %s without restarting active Quadlet containers.\n' "$profile" "$target"
