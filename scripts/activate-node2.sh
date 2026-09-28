#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" 'set -Eeuo pipefail; nginx -t; fail2ban-client ping; systemctl reload nginx; systemctl restart fail2ban; if command -v podman-compose >/dev/null && test -f /home/doom/observability/observability-compose.yaml; then runuser -u doom -- env XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/doom podman-compose -f /home/doom/observability/observability-compose.yaml up -d; fi; echo activation-ok'
