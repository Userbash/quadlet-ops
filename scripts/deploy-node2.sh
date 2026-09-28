#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
unit_name=${2:-portainer}
[[ $unit_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || die 'unit name must start with a letter or digit and contain only letters, digits, dot, underscore, @, or hyphen'
confirm_write
unit="$(dirname "$0")/../deploy/$unit_name.container"
[[ -f "$unit" ]] || die "Quadlet container definition is missing: $unit"
need_cmd ssh
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" 'id doom >/dev/null && command -v podman >/dev/null && loginctl show-user doom -p Linger --value | grep -qx yes'
ssh -o BatchMode=yes "$target" "install -d -o doom -g doom -m 0750 /home/doom/.config/containers/systemd /home/doom/$unit_name/data"
ssh -o BatchMode=yes "$target" "install -o doom -g doom -m 0644 /dev/stdin /home/doom/.config/containers/systemd/$unit_name.container" < "$unit"
service_uid=$(ssh -o BatchMode=yes "$target" 'id -u doom')
runtime_dir="/run/user/$service_uid"
ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user daemon-reload && runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user enable --now '$unit_name.service' && runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active '$unit_name.service'"
if [[ $unit_name == portainer ]]; then
  ssh -o BatchMode=yes "$target" 'curl --fail --silent --show-error --insecure --retry 20 --retry-connrefused --retry-delay 1 --max-time 3 https://127.0.0.1:9443/api/status >/dev/null'
  printf 'Portainer deployed on %s; its HTTPS endpoint is bound to localhost:9443.\n' "$target"
else
  printf 'Container service %s deployed on %s under the doom user systemd manager.\n' "$unit_name" "$target"
fi
