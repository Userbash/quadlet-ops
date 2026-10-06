#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib/common.sh"
load_env
need_cmd ssh
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
dest=${2:-${BACKUP_ROOT:-backups}}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$dest/node2-$stamp"
mkdir -p "$out"/{manifest,configs,doom}
chmod 0700 "$out" "$out/manifest" "$out/configs" "$out/doom"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'bash -s' > "$out/configs/host-configs.tar.gz" <<'REMOTE_HOST'
set -Eeuo pipefail
shopt -s nullglob
paths=(
  etc/nginx/nginx.conf
  etc/nginx/snippets/proxy-common.conf
  etc/nginx/sites-available/terranex.conf
  etc/fail2ban/fail2ban.local
  etc/fail2ban/jail.local
  etc/ufw/user.rules
  etc/ufw/user6.rules
  etc/ufw/ufw.conf
)
for pattern in \
  etc/nginx/conf.d/*.conf \
  etc/fail2ban/filter.d/node2-*.conf \
  etc/fail2ban/jail.d/*.local \
  etc/systemd/system/node2-*.service \
  etc/systemd/system/node2-*.timer \
  etc/systemd/system/doh-*.service \
  etc/systemd/system/doh-*.timer \
  etc/letsencrypt/renewal/*.conf; do
  [[ -f $pattern ]] && paths+=("$pattern")
done
existing=()
for path in "${paths[@]}"; do [[ -f /$path ]] && existing+=("$path"); done
tar -C / -czf - -- "${existing[@]}"
REMOTE_HOST

ssh -o BatchMode=yes "$target" 'bash -s' > "$out/doom/doom-configs.tar.gz" <<'REMOTE_DOOM'
set -Eeuo pipefail
shopt -s nullglob
paths=(
  home/doom/dnsserver-kube.yaml
  home/doom/bin/redis-entrypoint.sh
  home/doom/nextcloud/php.ini
  home/doom/observability/config.alloy
  home/doom/observability/loki-config.yaml
)
for pattern in \
  home/doom/.config/containers/systemd/*.container \
  home/doom/.config/containers/systemd/*.kube \
  home/doom/.config/containers/systemd/*.network \
  home/doom/.config/containers/systemd/*.volume \
  home/doom/.config/systemd/user/node2-*.service \
  home/doom/.config/systemd/user/node2-*.timer \
  home/doom/observability/bin/*.sh \
  home/doom/observability/technitium*.py; do
  [[ -f $pattern ]] && paths+=("$pattern")
done
existing=()
for path in "${paths[@]}"; do [[ -f /$path ]] && existing+=("$path"); done
tar -C / -czf - -- "${existing[@]}"
REMOTE_DOOM

# Application env files, auth hashes, TLS private keys, database/config.php,
# DNS zones, uploads, logs, caches, images, and named-volume contents are excluded.
(cd "$out"; sha256sum configs/host-configs.tar.gz doom/doom-configs.tar.gz > checksums.sha256)
chmod 0600 "$out"/configs/*.tar.gz "$out"/doom/*.tar.gz "$out/checksums.sha256"
printf 'Configuration-only backup created: %s\n' "$out"
