#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" 'set -Eeuo pipefail; nginx -t; fail2ban-client ping; systemctl reload nginx; systemctl restart fail2ban; if command -v podman-compose >/dev/null && test -f /home/doom/observability/observability-compose.yaml; then service_uid=$(id -u doom); runtime_dir=/run/user/$service_uid; runuser -u doom -- env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" HOME=/home/doom podman-compose -f /home/doom/observability/observability-compose.yaml up -d; fi; echo activation-ok'
