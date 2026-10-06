#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
unit_name=${2:-portainer}
[[ $unit_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || die 'invalid Quadlet service name'
confirm_write
need_cmd ssh
repo_root=$(cd "$(dirname "$0")/.." && pwd)
manifest_dir="$repo_root/deploy/quadlet/node2"
unit="$manifest_dir/$unit_name.container"
extension=container
if [[ ! -f $unit && -f $manifest_dir/$unit_name.kube ]]; then
  unit="$manifest_dir/$unit_name.kube"
  extension=kube
fi
[[ -f $unit ]] || die "node2 Quadlet definition not found: $unit_name"

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" \
  'id doom >/dev/null && command -v podman >/dev/null && loginctl show-user doom -p Linger --value | grep -qx yes'
quadlet_dir=/home/doom/.config/containers/systemd
ssh "$target" "install -d -o doom -g doom -m 0750 '$quadlet_dir'"
manifest_files=("$unit_name.$extension")
for companion in "$manifest_dir"/*.network "$manifest_dir"/*.volume; do
  [[ -f $companion ]] && manifest_files+=("$(basename "$companion")")
done
[[ $extension != kube ]] || manifest_files+=(dnsserver-kube.yaml)
tar -C "$manifest_dir" -cf - -- "${manifest_files[@]}" |
  ssh -o BatchMode=yes "$target" "runuser -u doom -- tar -C '$quadlet_dir' -xf -"

service_uid=$(ssh -o BatchMode=yes "$target" 'id -u doom')
runtime_dir="/run/user/$service_uid"
if [[ $extension == kube ]]; then
  unit_name="$unit_name"
fi
ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user daemon-reload"
if ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active --quiet '$unit_name.service'"; then
  action=restart
else
  action=start
fi
ssh -o BatchMode=yes "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user '$action' '$unit_name.service' && runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus' systemctl --user is-active '$unit_name.service'"

case $unit_name in
  portainer)
    ssh "$target" 'curl --fail --silent --show-error --insecure --retry 30 --retry-connrefused --retry-delay 1 --max-time 3 https://127.0.0.1:9443/api/status >/dev/null'
    ;;
  socraticode-qdrant)
    ssh "$target" 'curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:6333/readyz >/dev/null'
    ;;
  loki)
    ssh "$target" 'curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:3100/ready >/dev/null'
    ;;
  victoria-metrics)
    ssh "$target" 'curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:8428/health >/dev/null'
    ;;
esac
printf 'Quadlet service %s deployed on %s as rootless doom.\n' "$unit_name" "$target"
