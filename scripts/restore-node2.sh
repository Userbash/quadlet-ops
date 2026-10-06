#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=${1:?target host required}
src=${2:?backup directory required}
target=$(ssh_target "$target")
[[ -f $src/checksums.sha256 ]] || die "backup manifest missing: $src/checksums.sha256"
(cd "$src"; sha256sum -c checksums.sha256)
archive_host=$src/configs/host-configs.tar.gz
archive_doom=$src/doom/doom-configs.tar.gz
[[ -f $archive_host && -f $archive_doom ]] || die 'configuration archives are missing'

validate_paths() {
  local archive=$1 kind=$2 path
  while IFS= read -r path; do
    [[ -n $path && $path != /* && $path != *'..'* ]] || die "unsafe path in $archive"
    if [[ $kind == host ]]; then
      [[ $path == etc/nginx/* || $path == etc/fail2ban/* || $path == etc/ufw/* || $path == etc/systemd/system/* || $path == etc/letsencrypt/renewal/* ]] || die "unexpected host path in $archive"
    else
      [[ $path == home/doom/.config/containers/systemd/* || $path == home/doom/.config/systemd/user/node2-* || $path == home/doom/observability/config.alloy || $path == home/doom/observability/loki-config.yaml || $path == home/doom/observability/bin/*.sh || $path == home/doom/observability/technitium*.py || $path == home/doom/nextcloud/php.ini || $path == home/doom/bin/redis-entrypoint.sh || $path == home/doom/dnsserver-kube.yaml ]] || die "unexpected service path in $archive"
      [[ $path != *.env && $path != */config.php && $path != *privkey* ]] || die "secret path in $archive"
    fi
  done < <(tar -tzf "$archive")
}
validate_paths "$archive_host" host
validate_paths "$archive_doom" doom
confirm_write
need_cmd ssh
need_cmd scp
local_stage=$(mktemp -d)
trap 'rm -rf -- "$local_stage"' EXIT
tar -tzf "$archive_doom" > "$local_stage/doom-paths.txt"
chmod 0600 "$local_stage/doom-paths.txt"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
remote_host=/tmp/node2-host-configs-$stamp.tar.gz
remote_doom=/tmp/node2-doom-configs-$stamp.tar.gz
remote_list=/tmp/node2-doom-paths-$stamp.txt
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" 'sudo install -d -m 0700 /root/node2-restore-review'
scp -o BatchMode=yes "$archive_host" "$target:$remote_host"
scp -o BatchMode=yes "$archive_doom" "$target:$remote_doom"
scp -o BatchMode=yes "$local_stage/doom-paths.txt" "$target:$remote_list"
ssh -o BatchMode=yes "$target" "sudo tar -xzf '$remote_host' -C / --no-same-owner --no-same-permissions && sudo tar -xzf '$remote_doom' -C / --no-same-owner --no-same-permissions && while IFS= read -r path; do case \$path in home/doom/*) sudo chown doom:doom \"/\$path\" ;; *) exit 1 ;; esac; done < '$remote_list' && sudo chown doom:doom /home/doom/.config/containers/systemd /home/doom/.config/systemd/user /home/doom/observability /home/doom/observability/bin /home/doom/nextcloud /home/doom/bin"
printf 'Configuration restored to %s. No services were restarted; validate before activation.\n' "$target"
