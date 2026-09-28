#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=${1:?target host required}; src=${2:?backup directory required}
target=$(ssh_target "$target")
[[ -f "$src/checksums.sha256" ]] || die "backup manifest missing: $src/checksums.sha256"
if grep -q '  backups/' "$src/checksums.sha256"; then
  sha256sum -c "$src/checksums.sha256"
else
  (cd "$src"; sha256sum -c checksums.sha256)
fi
confirm_write
need_cmd ssh; need_cmd scp
archive_host=$src/configs/host-configs.tar.gz
archive_doom=$src/doom/doom-configs.tar.gz
[[ -f "$archive_host" && -f "$archive_doom" ]] || die 'backup archives are missing'
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" 'sudo mkdir -p /root/node2-restore-review /home/doom'
scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$archive_host" "$target:/tmp/node2-host-configs.tar.gz"
scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$archive_doom" "$target:/tmp/node2-doom-configs.tar.gz"
ssh -o BatchMode=yes "$target" 'sudo tar -xzf /tmp/node2-host-configs.tar.gz -C /; sudo tar -xzf /tmp/node2-doom-configs.tar.gz -C /; sudo chown -R doom:doom /home/doom/.config /home/doom/observability 2>/dev/null || true; echo restore-complete'
log 'restore completed; services were not restarted'
