#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" 'bash -s' <<'REMOTE'
set -Eeuo pipefail
nginx -t
fail2ban-client ping
systemctl is-active --quiet nginx fail2ban
uid=$(id -u doom)
runtime=/run/user/$uid
user_env=(runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus")
for service in portainer victoria-metrics loki alloy socraticode-qdrant 3xui open-webui nextcloud-db nextcloud-redis nextcloud-rabbitmq nextcloud-app nextcloud-cron dnsserver-quadlet query-events; do
  if [[ -e /home/doom/.config/containers/systemd/$service.container || -e /home/doom/.config/containers/systemd/$service.kube ]]; then
    "${user_env[@]}" systemctl --user is-active --quiet "$service.service" || {
      echo "inactive rootless Quadlet service: $service" >&2
      exit 1
    }
  fi
done
if "${user_env[@]}" systemctl --user is-active --quiet alloy.service; then
  "${user_env[@]}" podman exec alloy /bin/alloy validate /etc/alloy/config.alloy >/dev/null
fi
for check in \
  'http://127.0.0.1:3100/ready' \
  'http://127.0.0.1:8428/health' \
  'http://127.0.0.1:6333/readyz'; do
  curl --fail --silent --show-error --max-time 5 "$check" >/dev/null
done
echo node2-validation-ok
REMOTE
