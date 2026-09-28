#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib/common.sh"
load_env
need_cmd ssh
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
dest=${2:-${BACKUP_ROOT:-backups}}; stamp=$(date -u +%Y%m%dT%H%M%SZ); out="$dest/node2-$stamp"
mkdir -p "$out"/{manifest,configs,doom,volumes}
ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "true"
ssh "$target" "sudo tar --numeric-owner --acls --xattrs -czf - /etc/nginx /etc/fail2ban /etc/ufw /etc/systemd/system 2>/dev/null" > "$out/configs/host-configs.tar.gz"
ssh "$target" "sudo ufw status verbose; sudo ufw show raw" > "$out/manifest/ufw.txt"
ssh "$target" "sudo nginx -T" > "$out/manifest/nginx-effective.conf"
ssh "$target" "sudo fail2ban-client status; for j in \$(sudo fail2ban-client status | sed -n 's/.*Jail list:\\s*//p' | tr ',' ' '); do sudo fail2ban-client status \"\$j\"; done" > "$out/manifest/fail2ban.txt"
ssh "$target" "uid=\$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid podman ps -a --format json; runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid podman images --format json" > "$out/manifest/podman.json"
ssh "$target" "uid=\$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid bash -c 'ids=\$(podman ps -aq); [ -z \"\$ids\" ] || podman inspect \$ids'" > "$out/manifest/containers-inspect.json" 2>/dev/null || true
ssh "$target" "uid=\$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid podman volume ls --format json; runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/\$uid podman network ls --format json" > "$out/manifest/volumes-networks.json"
ssh "$target" "tar --numeric-owner --acls --xattrs --exclude=/home/doom/nextcloud/data --exclude=/home/doom/nextcloud/db --exclude=/home/doom/nextcloud/app --exclude=/home/doom/nextcloud/apps --exclude=/home/doom/.cache --exclude=/home/doom/.local/share/containers/storage --exclude=/home/doom/3x-ui/node_modules --exclude=/home/doom/3x-ui/frontend/node_modules -czf - /home/doom/.config/containers /home/doom/.config/systemd/user /home/doom/portander /home/doom/observability /home/doom/dns-config /home/doom/open-webui /home/doom/nextcloud /home/doom/3x-ui 2>/dev/null" > "$out/doom/doom-configs.tar.gz"
# Volume names and mount metadata are recorded above. Exporting live volume data is
# intentionally separate because it can be large; add explicit volume archives here
# after reviewing storage requirements.
(cd "$out"; find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256)
printf 'Backup created: %s\n' "$out"
