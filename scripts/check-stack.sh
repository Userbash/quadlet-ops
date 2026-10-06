#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
profile=${2:-node2-full}
profile_file="$(dirname "$0")/../deploy/profiles/$profile.units"
[[ -f $profile_file ]] || die "unknown deployment profile: $profile"
need_cmd ssh
runtime_uid=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'id -u doom')
runtime_dir=/run/user/$runtime_uid

while IFS= read -r unit_name; do
  unit_name=${unit_name%%#*}
  unit_name=${unit_name//[[:space:]]/}
  [[ -n $unit_name ]] || continue
  if [[ $unit_name == dns-stats && -z ${NODE2_TECHNITIUM_API_TOKEN:-} ]]; then
    printf 'not checked (optional token not configured): %s\n' "$unit_name"
    continue
  fi
  if ! ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active --quiet '$unit_name.service'"; then
    ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user --no-pager --full status '$unit_name.service'" || true
    die "Quadlet service is not active: $unit_name.service"
  fi
  case $unit_name in
    portainer) ssh "$target" 'curl --fail --silent --show-error --insecure --max-time 5 https://127.0.0.1:9443/api/status >/dev/null' ;;
    socraticode-qdrant) ssh "$target" 'curl --fail --silent --show-error --max-time 5 http://127.0.0.1:6333/readyz >/dev/null' ;;
    loki) ssh "$target" 'curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3100/ready >/dev/null' ;;
    victoria-metrics) ssh "$target" 'curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8428/health >/dev/null' ;;
  esac
done < "$profile_file"
printf 'Read-only status and readiness checks passed for profile %s on %s.\n' "$profile" "$target"
