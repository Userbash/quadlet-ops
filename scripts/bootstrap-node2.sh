#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'bootstrap must run as root' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq nginx fail2ban certbot podman podman-compose uidmap slirp4netns fuse-overlayfs dbus-user-session apache2-utils openssl tar gzip acl
id doom >/dev/null 2>&1 || useradd --create-home --shell /bin/bash doom
[[ $(getent passwd doom | cut -d: -f6) == /home/doom ]] || { echo 'doom must use /home/doom as its home directory' >&2; exit 1; }

ensure_subid_range() {
  local file=$1 total candidate conflict
  [[ -e "$file" ]] || install -m 0644 /dev/null "$file"
  total=$(awk -F: '$1 == "doom" { sum += $3 } END { print sum + 0 }' "$file")
  (( total >= 65536 )) && return
  candidate=100000
  while :; do
    conflict=$(awk -F: -v start="$candidate" 'NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && start < $2 + $3 && $2 < start + 65536 { print $2 + $3; exit }' "$file")
    [[ -z "$conflict" ]] && break
    candidate=$conflict
  done
  printf 'doom:%s:65536\n' "$candidate" >> "$file"
}

ensure_subid_range /etc/subuid
ensure_subid_range /etc/subgid
install -d -o doom -g doom -m 0750 /home/doom/observability /home/doom/backups /home/doom/portainer /home/doom/portainer/data /home/doom/portainer/secrets /home/doom/.config /home/doom/.config/containers /home/doom/.config/containers/systemd
if [[ ! -s /home/doom/portainer/secrets/admin-password ]]; then
  admin_password=$(openssl rand -hex 24)
  admin_hash=$(htpasswd -bnBC 12 '' "$admin_password" | cut -d: -f2-)
  printf '%s\n' "$admin_hash" > /home/doom/portainer/secrets/admin-password
  credential_key=password
  printf 'username=admin\n%s=%s\n' "$credential_key" "$admin_password" > /home/doom/portainer/secrets/admin-credentials.txt
  chown doom:doom /home/doom/portainer/secrets/admin-password
  chmod 0600 /home/doom/portainer/secrets/admin-password
  chown root:root /home/doom/portainer/secrets/admin-credentials.txt
  chmod 0600 /home/doom/portainer/secrets/admin-credentials.txt
fi
loginctl enable-linger doom
service_uid=$(id -u doom)
runtime_dir=/run/user/$service_uid
systemctl start "user@$service_uid.service"
for _ in {1..20}; do
  if systemctl is-active --quiet "user@$service_uid.service" && [[ -d "$runtime_dir" ]]; then
    break
  fi
  sleep 0.25
done
systemctl is-active --quiet "user@$service_uid.service" || { echo 'doom user systemd manager did not become active' >&2; exit 1; }
[[ -d "$runtime_dir" ]] || { echo "missing user runtime directory: $runtime_dir" >&2; exit 1; }
runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" systemctl --user enable --now podman.socket
runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" systemctl --user is-active --quiet podman.socket
[[ -S "$runtime_dir/podman/podman.sock" ]] || { echo 'rootless Podman socket is missing' >&2; exit 1; }
runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" podman info >/dev/null
runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" podman volume inspect portainer_data >/dev/null 2>&1 || runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" podman volume create portainer_data >/dev/null
runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime_dir" podman volume inspect portainer_data >/dev/null
systemctl enable --now nginx fail2ban
systemctl is-active --quiet nginx fail2ban
echo 'bootstrap complete: rootless Podman is ready for doom; SSH, DNS, TLS, and firewall policy were left unchanged'
