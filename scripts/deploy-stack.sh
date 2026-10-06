#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
profile=${2:-node2-full}
confirm_write
need_cmd ssh
need_cmd tar
repo_root=$(cd "$(dirname "$0")/.." && pwd)
profile_file="$repo_root/deploy/profiles/$profile.units"
[[ -f $profile_file ]] || die "unknown deployment profile: $profile"
[[ ${NODE2_DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $NODE2_DOMAIN != *.example.com ]] || die 'set a real NODE2_DOMAIN in .env before deploying the stack'

mapfile -t services < <(sed -E 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$profile_file")
(( ${#services[@]} > 0 )) || die "empty deployment profile: $profile"
for service in "${services[@]}"; do
  [[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || die "invalid service in profile: $service"
  [[ -f $repo_root/deploy/quadlet/node2/$service.container || -f $repo_root/deploy/quadlet/node2/$service.kube ]] || die "profile references missing node2 Quadlet: $service"
done

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" \
  'id doom >/dev/null && command -v podman >/dev/null && loginctl show-user doom -p Linger --value | grep -qx yes'

install_as_doom() {
  local source=$1 destination=$2 mode=$3
  ssh "$target" "runuser -u doom -- install -D -m '$mode' /dev/stdin '$destination'" < "$source"
}

install_as_doom "$repo_root/deploy/config/alloy/config.alloy" /home/doom/observability/config.alloy 0644
install_as_doom "$repo_root/deploy/config/loki/loki-config.yaml" /home/doom/observability/loki-config.yaml 0644
install_as_doom "$repo_root/deploy/config/nextcloud/php.ini" /home/doom/nextcloud/php.ini 0644
install_as_doom "$repo_root/deploy/config/nextcloud/redis-entrypoint.sh" /home/doom/bin/redis-entrypoint.sh 0755
install_as_doom "$repo_root/deploy/config/dns/technitium_query_producer.py" /home/doom/observability/technitium_query_producer.py 0644
install_as_doom "$repo_root/deploy/config/dns/technitium_stats_collector.py" /home/doom/observability/technitium_stats_collector.py 0644
install_as_doom "$repo_root/deploy/quadlet/node2/dnsserver-kube.yaml" /home/doom/dnsserver-kube.yaml 0644

runtime_uid=$(ssh "$target" 'id -u doom')
runtime_dir=/run/user/$runtime_uid
ssh "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' NODE2_DOMAIN='$NODE2_DOMAIN' bash -s" \
  < "$repo_root/scripts/prepare-node2-user.sh"

# 3x-ui is a local-only image on the current server. Build a pinned upstream
# release under doom so a clean VPS can reproduce it without copying app data.
ssh "$target" "runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR='$runtime_dir' bash -s" \
  < "$repo_root/scripts/build-3xui.sh"

if [[ -n ${NODE2_TECHNITIUM_API_TOKEN:-} ]]; then
  [[ $NODE2_TECHNITIUM_API_TOKEN =~ ^[A-Za-z0-9._-]{16,512}$ ]] || die 'NODE2_TECHNITIUM_API_TOKEN has an invalid format'
  printf 'TECHNITIUM_API_BASE=http://127.0.0.1:5380\nTECHNITIUM_API_TOKEN=%s\n' "$NODE2_TECHNITIUM_API_TOKEN" |
    ssh "$target" 'runuser -u doom -- install -m 0600 /dev/stdin /home/doom/observability/technitium.env'
fi

for service in "${services[@]}"; do
  if [[ $service == dns-stats && -z ${NODE2_TECHNITIUM_API_TOKEN:-} ]]; then
    printf 'Skipping optional %s: NODE2_TECHNITIUM_API_TOKEN is not set.\n' "$service"
    continue
  fi
  "$repo_root/scripts/deploy-node2.sh" "$target" "$service"
done

printf 'Profile %s installed on %s. Host Nginx/TLS and Fail2Ban require DNS and are configured separately with configure-web.fish.\n' "$profile" "$target"
