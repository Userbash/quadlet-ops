#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'bootstrap must run as root' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq nginx fail2ban podman podman-compose tar gzip acl
id doom >/dev/null 2>&1 || useradd --create-home --shell /bin/bash doom
install -d -o doom -g doom -m 0750 /home/doom/observability /home/doom/backups
systemctl enable --now nginx fail2ban
echo 'bootstrap complete; SSH, DNS, TLS and firewall policy were left unchanged'
