#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
[[ ${NODE2_DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $NODE2_DOMAIN != *.example.com ]] || die 'set a real NODE2_DOMAIN in .env'
need_cmd ssh
need_cmd scp

repo_root=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
stage="/root/node2-metrics-stage-$stamp-$$"
remote="/run/node2-metrics-$stamp"
local_tmp=$(mktemp -d)
cleanup() { rm -rf -- "$local_tmp"; }
trap cleanup EXIT

for path in \
  deploy/quadlet/node2/victoria-metrics.container \
  deploy/systemd/user/node2-capacity-metrics.service \
  deploy/systemd/user/node2-capacity-metrics.timer \
  deploy/systemd/user/node2-metric-actions.service \
  deploy/systemd/user/node2-metric-actions.timer \
  scripts/node2-metric-actions.sh \
  deploy/config/alloy/node2-metrics.alloy \
  deploy/host/fail2ban/node2-fail2ban-metrics.patch \
  deploy/host/nginx/conf.d/node2-metrics-log-format.conf \
  deploy/host/nginx/nginx-metrics-logrotate.conf \
  deploy/host/nginx/conf.d/node2-nginx-stub-status.conf \
  deploy/host/nginx/patches/node2-nginx-metrics.patch \
  deploy/host/nginx/patches/node2-nextcloud-correlation.patch \
  deploy/host/nginx/patches/node2-xhttp-log-format.patch \
  deploy/host/nginx/patches/node2-xhttp-request-size.patch \
  scripts/collect-node2-metrics.sh; do
  [[ -f "$repo_root/$path" ]] || die "required file missing: $path"
done

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" \
  "id doom >/dev/null && command -v podman >/dev/null && command -v nginx >/dev/null && command -v ss >/dev/null && command -v setfacl >/dev/null && command -v logrotate >/dev/null && command -v patch >/dev/null && loginctl show-user doom -p Linger --value | grep -qx yes && install -d -m 0700 '$stage'"
scp -q -o BatchMode=yes -r \
  "$repo_root/deploy/quadlet/node2/victoria-metrics.container" \
  "$repo_root/deploy/systemd/user/node2-capacity-metrics.service" \
  "$repo_root/deploy/systemd/user/node2-capacity-metrics.timer" \
  "$repo_root/deploy/systemd/user/node2-metric-actions.service" \
  "$repo_root/deploy/systemd/user/node2-metric-actions.timer" \
  "$repo_root/scripts/node2-metric-actions.sh" \
  "$repo_root/deploy/config/alloy/node2-metrics.alloy" \
  "$repo_root/deploy/host/fail2ban/node2-fail2ban-metrics.patch" \
  "$repo_root/deploy/host/nginx/conf.d/node2-metrics-log-format.conf" \
  "$repo_root/deploy/host/nginx/nginx-metrics-logrotate.conf" \
  "$repo_root/deploy/host/nginx/conf.d/node2-nginx-stub-status.conf" \
  "$repo_root/deploy/host/nginx/patches/node2-nginx-metrics.patch" \
  "$repo_root/deploy/host/nginx/patches/node2-nextcloud-correlation.patch" \
  "$repo_root/deploy/host/nginx/patches/node2-xhttp-log-format.patch" \
  "$repo_root/deploy/host/nginx/patches/node2-xhttp-request-size.patch" \
  "$repo_root/scripts/collect-node2-metrics.sh" "$target:$stage/"

cat > "$local_tmp/install-remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
stage=${1:?staging path required}
backup=${2:?backup path required}
domain=${3:?node2 domain required}
uid=$(id -u doom)
runtime=/run/user/$uid
user_env=(runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus")
cd /home/doom
quadlets=/home/doom/.config/containers/systemd
unit_dir=/home/doom/.config/systemd/user
alloy_config=/home/doom/observability/config.alloy
nginx_site=/etc/nginx/sites-enabled/terranex.conf
xhttp_log_config=/etc/nginx/conf.d/xhttp-hardening.conf
nginx_status_config=/etc/nginx/conf.d/node2-nginx-stub-status.conf
managed_begin='// BEGIN NODE2_METRICS_MANAGED'
managed_end='// END NODE2_METRICS_MANAGED'
installed=0
unit_changed=0
alloy_changed=0
nginx_changed=0
site_changed=0

rollback() {
  rc=$?
  trap - EXIT
  rm -f /home/doom/observability/.node2-metrics-candidate.alloy
  if (( rc != 0 && installed )); then
    cp -a "$backup/config.alloy" "$alloy_config" 2>/dev/null || true
    cp -a "$backup/terranex.conf" "$nginx_site" 2>/dev/null || true
    cp -a "$backup/xhttp-hardening.conf" "$xhttp_log_config" 2>/dev/null || true
    if [[ -e $backup/nginx-status.conf ]]; then cp -a "$backup/nginx-status.conf" "$nginx_status_config"; else rm -f "$nginx_status_config"; fi
    if [[ -e $backup/collect-node2-metrics.sh ]]; then
      cp -a "$backup/collect-node2-metrics.sh" /home/doom/observability/bin/collect-node2-metrics.sh
    else
      rm -f /home/doom/observability/bin/collect-node2-metrics.sh
    fi
    if [[ -e $backup/victoria-metrics.container ]]; then
      cp -a "$backup/victoria-metrics.container" "$quadlets/victoria-metrics.container"
    else
      "${user_env[@]}" systemctl --user disable --now victoria-metrics.service 2>/dev/null || true
      rm -f "$quadlets/victoria-metrics.container"
    fi
    for f in node2-capacity-metrics.service node2-capacity-metrics.timer node2-metric-actions.service node2-metric-actions.timer; do
      if [[ -e $backup/$f ]]; then
        cp -a "$backup/$f" "$unit_dir/$f"
      else
        unit=${f%.timer}; unit=${unit%.service}
        [[ $f != *.timer ]] || unit="$unit.timer"
        [[ $f != *.service ]] || unit="$unit.service"
        "${user_env[@]}" systemctl --user disable --now "$unit" 2>/dev/null || true
        rm -f "$unit_dir/$f"
      fi
    done
    if [[ -e $backup/node2-metric-actions.sh ]]; then
      cp -a "$backup/node2-metric-actions.sh" /home/doom/observability/bin/node2-metric-actions.sh
    else
      rm -f /home/doom/observability/bin/node2-metric-actions.sh
    fi
    if [[ -e $backup/logrotate-node2-metrics ]]; then cp -a "$backup/logrotate-node2-metrics" /etc/logrotate.d/node2-metrics; else rm -f /etc/logrotate.d/node2-metrics; fi
    if [[ -e $backup/nginx-node2-metrics-format ]]; then cp -a "$backup/nginx-node2-metrics-format" /etc/nginx/conf.d/node2-metrics-log-format.conf; else rm -f /etc/nginx/conf.d/node2-metrics-log-format.conf; fi
    if (( unit_changed )); then "${user_env[@]}" systemctl --user daemon-reload || true; fi
    if (( alloy_changed )); then "${user_env[@]}" systemctl --user restart alloy.service || true; fi
    if (( nginx_changed )); then nginx -t && systemctl reload nginx || true; fi
  fi
  exit "$rc"
}
trap rollback EXIT

install -d -m 0700 "$backup"
for f in config.alloy terranex.conf; do
  case $f in config.alloy) src=$alloy_config;; terranex.conf) src=$nginx_site;; esac
  [[ -f $src ]] || { echo "missing required live config: $src" >&2; exit 1; }
  cp -a "$src" "$backup/$f"
done
[[ -f $xhttp_log_config ]] || { echo "missing required live config: $xhttp_log_config" >&2; exit 1; }
cp -a "$xhttp_log_config" "$backup/xhttp-hardening.conf"
[[ ! -e $nginx_status_config ]] || cp -a "$nginx_status_config" "$backup/nginx-status.conf"
[[ ! -e $quadlets/victoria-metrics.container ]] || cp -a "$quadlets/victoria-metrics.container" "$backup/victoria-metrics.container"
for f in node2-capacity-metrics.service node2-capacity-metrics.timer node2-metric-actions.service node2-metric-actions.timer; do
  [[ ! -e $unit_dir/$f ]] || cp -a "$unit_dir/$f" "$backup/$f"
done
[[ ! -e /etc/logrotate.d/node2-metrics ]] || cp -a /etc/logrotate.d/node2-metrics "$backup/logrotate-node2-metrics"
[[ ! -e /etc/nginx/conf.d/node2-metrics-log-format.conf ]] || cp -a /etc/nginx/conf.d/node2-metrics-log-format.conf "$backup/nginx-node2-metrics-format"
[[ ! -e /home/doom/observability/bin/collect-node2-metrics.sh ]] || cp -a /home/doom/observability/bin/collect-node2-metrics.sh "$backup/collect-node2-metrics.sh"
[[ ! -e /home/doom/observability/bin/node2-metric-actions.sh ]] || cp -a /home/doom/observability/bin/node2-metric-actions.sh "$backup/node2-metric-actions.sh"
installed=1

# Validate the Nginx patch on a copy, then apply it to the live file only if all
# expected access-log locations are still present and no metrics logs exist.
cp "$nginx_site" "$backup/terranex.candidate"
metric_count=$(grep -Ec 'access_log[[:space:]]+/var/log/nginx/metrics/' "$backup/terranex.candidate" || true)
if [[ $metric_count == 0 ]]; then
  patch --batch --forward --silent "$backup/terranex.candidate" "$stage/node2-nginx-metrics.patch"
  site_changed=1
elif [[ $metric_count != 6 ]]; then
  echo "unexpected partial metric log configuration ($metric_count entries); refusing" >&2
  exit 1
fi
if ! grep -Fq '/var/log/nginx/incident-correlation/nextcloud.log node2_incident' "$backup/terranex.candidate"; then
  patch --batch --forward --silent "$backup/terranex.candidate" "$stage/node2-nextcloud-correlation.patch"
  site_changed=1
fi

cp "$xhttp_log_config" "$backup/xhttp-hardening.candidate"
if ! grep -Fq 'limit_conn=$limit_conn_status' "$backup/xhttp-hardening.candidate"; then
  patch --batch --forward --silent "$backup/xhttp-hardening.candidate" "$stage/node2-xhttp-log-format.patch"
fi
if ! grep -Fq 'request_length=$request_length' "$backup/xhttp-hardening.candidate"; then
  patch --batch --forward --silent "$backup/xhttp-hardening.candidate" "$stage/node2-xhttp-request-size.patch"
fi

# Build and validate Alloy config using the running image before changing it.
if grep -Fq "$managed_begin" "$alloy_config"; then
  awk -v begin="$managed_begin" -v end="$managed_end" '
    index($0, begin) {drop=1; next}
    index($0, end) {drop=0; next}
    !drop {print}
  ' "$alloy_config" > "$backup/config.candidate"
else
  cp "$alloy_config" "$backup/config.candidate"
fi
cat "$stage/node2-metrics.alloy" >> "$backup/config.candidate"
if ! grep -Fq 'name = "fail2ban_jail_events_total"' "$backup/config.candidate"; then
  patch --batch --forward --silent "$backup/config.candidate" "$stage/node2-fail2ban-metrics.patch"
fi
install -o doom -g doom -m 0644 "$backup/config.candidate" /home/doom/observability/.node2-metrics-candidate.alloy
"${user_env[@]}" podman cp /home/doom/observability/.node2-metrics-candidate.alloy alloy:/tmp/node2-metrics.alloy
"${user_env[@]}" podman exec alloy /bin/alloy validate /tmp/node2-metrics.alloy
rm -f /home/doom/observability/.node2-metrics-candidate.alloy
logrotate -d "$stage/nginx-metrics-logrotate.conf" >/dev/null

install -d -o doom -g doom -m 0750 "$quadlets" "$unit_dir" /home/doom/observability/bin /home/doom/.local/state/node2-metrics /home/doom/.local/state/node2-metric-actions
unit_changed=1
install -o doom -g doom -m 0644 "$stage/victoria-metrics.container" "$quadlets/victoria-metrics.container"
install -o doom -g doom -m 0644 "$stage/node2-capacity-metrics.service" "$unit_dir/node2-capacity-metrics.service"
install -o doom -g doom -m 0644 "$stage/node2-capacity-metrics.timer" "$unit_dir/node2-capacity-metrics.timer"
install -o doom -g doom -m 0644 "$stage/node2-metric-actions.service" "$unit_dir/node2-metric-actions.service"
install -o doom -g doom -m 0644 "$stage/node2-metric-actions.timer" "$unit_dir/node2-metric-actions.timer"
install -o doom -g doom -m 0750 "$stage/collect-node2-metrics.sh" /home/doom/observability/bin/collect-node2-metrics.sh
install -o doom -g doom -m 0750 "$stage/node2-metric-actions.sh" /home/doom/observability/bin/node2-metric-actions.sh
nginx_changed=1
install -o root -g root -m 0644 "$stage/node2-metrics-log-format.conf" /etc/nginx/conf.d/node2-metrics-log-format.conf
install -o root -g root -m 0644 "$stage/nginx-metrics-logrotate.conf" /etc/logrotate.d/node2-metrics
install -o root -g root -m 0644 "$stage/node2-nginx-stub-status.conf" "$nginx_status_config"

# The dedicated directory keeps the new privacy-minimized logs out of existing
# Alloy globs. ACLs let the rootless Alloy bind mount read newly rotated files.
install -d -o root -g adm -m 0750 /var/log/nginx/metrics
setfacl -m u:doom:rx /var/log/nginx/metrics
setfacl -d -m u:doom:r-- /var/log/nginx/metrics
install -d -o root -g adm -m 0750 /var/log/nginx/incident-correlation
setfacl -m u:doom:rx /var/log/nginx/incident-correlation
setfacl -d -m u:doom:r-- /var/log/nginx/incident-correlation

install -o doom -g doom -m 0644 "$backup/config.candidate" "$alloy_config"
alloy_changed=1
if (( site_changed )); then install -o root -g root -m 0644 "$backup/terranex.candidate" "$nginx_site"; fi
install -o root -g root -m 0644 "$backup/xhttp-hardening.candidate" "$xhttp_log_config"
nginx -t
logrotate -d /etc/logrotate.d/node2-metrics >/dev/null
logrotate -d /etc/logrotate.conf >/dev/null 2>&1

"${user_env[@]}" systemctl --user daemon-reload
"${user_env[@]}" systemctl --user start victoria-metrics.service
for i in $(seq 1 30); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8428/health >/dev/null; then break; fi
  [[ $i -lt 30 ]] || { echo 'VictoriaMetrics readiness timeout' >&2; exit 1; }
  sleep 1
done

# Verify the exact generated unit before enabling it, then start the collector.
"${user_env[@]}" systemctl --user cat victoria-metrics.service >/dev/null
"${user_env[@]}" systemctl --user enable --now node2-capacity-metrics.timer
"${user_env[@]}" systemctl --user restart node2-capacity-metrics.timer
"${user_env[@]}" systemctl --user start node2-capacity-metrics.service
"${user_env[@]}" systemctl --user restart alloy.service
for i in $(seq 1 30); do
  if "${user_env[@]}" systemctl --user is-active --quiet alloy.service; then break; fi
  [[ $i -lt 30 ]] || { echo 'Alloy readiness timeout' >&2; exit 1; }
  sleep 1
done
systemctl reload nginx

status_body=$(curl --fail --silent --show-error --connect-timeout 1 --max-time 3 http://127.0.0.1:9913/nginx_status)
grep -q '^Active connections:' <<< "$status_body"
listener=$(ss -Hlnpt 'sport = :9913')
[[ -n $listener && $(wc -l <<< "$listener") == 1 ]] && awk '$4 == "127.0.0.1:9913" {ok=1} END {exit !ok}' <<< "$listener" || { echo 'Nginx status endpoint is not loopback-only' >&2; exit 1; }

cloud_status=$(curl -k -sS -o /dev/null --connect-timeout 3 --max-time 10 --resolve "cloud.$domain:443:127.0.0.1" -w '%{http_code}' "https://cloud.$domain/status.php")
ai_status=$(curl -k -sS -o /dev/null --connect-timeout 3 --max-time 10 --resolve "ai.$domain:443:127.0.0.1" -w '%{http_code}' "https://ai.$domain/")
[[ $cloud_status == 200 && ( $ai_status == 200 || $ai_status == 404 ) ]] || { echo "post-deploy HTTP checks failed: cloud=$cloud_status ai=$ai_status" >&2; exit 1; }

for i in $(seq 1 40); do
  result=$(curl --fail --silent --max-time 3 'http://127.0.0.1:8428/api/v1/query?query=node2_nextcloud_http_status_up' || true)
  if grep -q '"resultType":"vector"' <<< "$result" && ! grep -q '"result":\[\]' <<< "$result"; then break; fi
  [[ $i -lt 40 ]] || { echo 'metrics not visible in VictoriaMetrics within timeout' >&2; exit 1; }
  sleep 2
done
"${user_env[@]}" systemctl --user enable --now node2-metric-actions.timer
trap - EXIT
installed=0
printf 'Metrics are active; rollback snapshot: %s\n' "$backup"
REMOTE

scp -q -o BatchMode=yes "$local_tmp/install-remote.sh" "$target:$stage/install-remote.sh"
if ssh -o BatchMode=yes "$target" "chmod 0700 '$stage/install-remote.sh' && '$stage/install-remote.sh' '$stage' '$remote' '$NODE2_DOMAIN' && rm -rf -- '$stage'"; then
  :
else
  ssh -o BatchMode=yes "$target" "rm -rf -- '$stage'" || true
  exit 1
fi
