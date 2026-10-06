#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
need_cmd ssh
need_cmd scp

repo_root=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
stage="/root/node2-fail2ban-stage-$stamp-$$"
backup="/run/fail2ban-node2-$stamp"
local_tmp=$(mktemp -d)
trap 'rm -rf -- "$local_tmp"' EXIT

for path in \
  deploy/host/fail2ban/fail2ban-nginx.local \
  deploy/host/fail2ban/filter.d/node2-edge-deny.conf \
  deploy/host/fail2ban/filter.d/node2-webscan.conf \
  deploy/host/fail2ban/filter.d/node2-panel-auth.conf \
  deploy/host/fail2ban/filter.d/node2-recidive.conf \
  deploy/host/fail2ban/filter.d/node2-xhttp-overlimit.conf; do
  [[ -f "$repo_root/$path" ]] || die "required file missing: $path"
done

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" \
  "command -v fail2ban-client >/dev/null && command -v fail2ban-regex >/dev/null && command -v patch >/dev/null && install -d -m 0700 '$stage'"
scp -q -o BatchMode=yes -r \
  "$repo_root/deploy/host/fail2ban/fail2ban-nginx.local" \
  "$repo_root/deploy/host/fail2ban/filter.d" "$target:$stage/"

cat > "$local_tmp/install-remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
stage=${1:?staging path required}
backup=${2:?backup path required}
config=/etc/fail2ban
overlay=jail.d/zzz-node2-automation.local
filters=(node2-edge-deny.conf node2-webscan.conf node2-panel-auth.conf node2-recidive.conf node2-xhttp-overlimit.conf)
ban_jails=(agent-producer nginx-webscan panel-auth)
changed=0

save_one() {
  local path=$1
  if [[ -e $config/$path ]]; then
    install -d -m 0700 "$backup/$(dirname "$path")"
    cp -a "$config/$path" "$backup/$path"
    install -d -m 0700 "$(dirname "$backup/present-$path")"
    : > "$backup/present-$path"
  fi
}

restore_one() {
  local path=$1
  if [[ -e $backup/present-$path ]]; then
    install -D -m 0644 "$backup/$path" "$config/$path"
  else
    rm -f "$config/$path"
  fi
}

rollback() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && changed )); then
    restore_one "$overlay"
    for f in "${filters[@]}"; do restore_one "filter.d/$f"; done
    fail2ban-client -t >/dev/null 2>&1 && fail2ban-client reload >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap rollback EXIT

install -d -m 0700 "$backup"
for p in "$overlay"; do save_one "$p"; done
for f in "${filters[@]}"; do save_one "filter.d/$f"; done

candidate="$backup/candidate"
cp -a "$config" "$candidate"
install -D -m 0644 "$stage/fail2ban-nginx.local" "$candidate/$overlay"
for f in "${filters[@]}"; do install -D -m 0644 "$stage/filter.d/$f" "$candidate/filter.d/$f"; done
fail2ban-client -c "$candidate" -t >/dev/null

matched_count() {
  local output count
  output=$(fail2ban-regex -c "$candidate" --verbosity 1 --print-no-missed --print-no-ignored "$1" "$2" 2>&1) || {
    printf 'filter execution failed for %s\n' "$2" >&2
    return 1
  }
  count=$(awk '/^Lines:/ {if (match($0, /[0-9]+ matched/)) {v=substr($0, RSTART, RLENGTH); sub(/ matched/, "", v); print v; exit}}' <<< "$output")
  [[ $count =~ ^[0-9]+$ ]] || { printf 'could not read match count for %s\n' "$2" >&2; return 1; }
  printf '%s\n' "$count"
}

positive_test() {
  local filter=$1 line=$2 count
  count=$(matched_count "$line" "$filter")
  (( count > 0 )) || { printf 'positive synthetic filter test failed: %s\n' "$filter" >&2; return 1; }
}

negative_test() {
  local filter=$1 line=$2 count
  count=$(matched_count "$line" "$filter")
  (( count == 0 )) || { printf 'negative synthetic filter test failed: %s\n' "$filter" >&2; return 1; }
}

stamp='06/Oct/2026:12:00:00 +0000'
positive_test node2-edge-deny '203.0.113.10 - - ['"$stamp"'] "GET / HTTP/1.1" 444 0 "-" "probe"'
negative_test node2-edge-deny '203.0.113.10 - - ['"$stamp"'] "GET / HTTP/1.1" 429 0 "-" "browser"'
positive_test node2-webscan '203.0.113.10 - - ['"$stamp"'] "GET /.env HTTP/1.1" 404 0 "-" "probe"'
negative_test node2-webscan '203.0.113.10 - - ['"$stamp"'] "GET /status.php HTTP/1.1" 404 0 "-" "browser"'
positive_test node2-panel-auth '203.0.113.10 - - ['"$stamp"'] "POST / HTTP/1.1" status=401'
negative_test node2-panel-auth '203.0.113.10 - - ['"$stamp"'] "POST / HTTP/1.1" status=429'
positive_test node2-xhttp-overlimit '203.0.113.10 [2026-10-06T09:10:00+00:00] "GET / HTTP/1.1" method=GET status=503 limit_conn=REJECTED bytes=0'
negative_test node2-xhttp-overlimit '203.0.113.10 [2026-10-06T09:10:00+00:00] "GET / HTTP/1.1" method=GET status=200 limit_conn=PASSED bytes=0'
positive_test node2-recidive '2026-10-06 12:00:00,000 fail2ban.actions [123]: NOTICE [nginx-webscan] Ban 203.0.113.10'
negative_test node2-recidive '2026-10-06 12:00:00,000 fail2ban.actions [123]: NOTICE [agent-producer] Ban 203.0.113.10'

# Test each candidate against real current or rotated logs without printing any
# matching lines or addresses. Keep thresholds high enough that historical
# events do not immediately create new bans during the reload.
edge_log=/var/log/nginx/access.log
panel_log=/var/log/nginx/panel_access.log
[[ -s $panel_log ]] || panel_log=/var/log/nginx/panel_access.log.1
for pair in "node2-edge-deny:$edge_log" "node2-webscan:$edge_log" "node2-panel-auth:$panel_log" "node2-recidive:/var/log/fail2ban.log" "node2-xhttp-overlimit:/var/log/nginx/xhttp_access.log"; do
  filter=${pair%%:*}
  logfile=${pair#*:}
  [[ -s $logfile ]] || continue
  count=$(matched_count "$logfile" "$filter")
  printf 'validated %s against %s: %s matches\n' "$filter" "$(basename "$logfile")" "$count"
done

ban_list() {
  fail2ban-client status "$1" 2>/dev/null | awk -F: '/Banned IP list:/ {sub(/^[^:]*:[[:space:]]*/, ""); print}' | tr ' ' '\n' | sed '/^$/d' | sort -u
}
for jail in "${ban_jails[@]}"; do ban_list "$jail" > "$backup/$jail.bans.before"; done

changed=1
install -D -m 0644 "$stage/fail2ban-nginx.local" "$config/$overlay"
for f in "${filters[@]}"; do install -D -m 0644 "$stage/filter.d/$f" "$config/filter.d/$f"; done
fail2ban-client -t >/dev/null
fail2ban-client reload >/dev/null
fail2ban-client ping >/dev/null

for jail in agent-producer nginx-webscan panel-auth xhttp-overlimit node2-recidive-7d node2-recidive-30d; do
  fail2ban-client status "$jail" >/dev/null
done
for jail in nginx-botsearch nginx-empty-useragent panel-dns-auth panel-rate panel-slow xhttp-protection panel-recidive-30d panel-recidive-90d; do
  if fail2ban-client status "$jail" >/dev/null 2>&1; then
    printf 'disabled jail unexpectedly remains loaded: %s\n' "$jail" >&2
    exit 1
  fi
done
lost_bans=0
for jail in "${ban_jails[@]}"; do
  ban_list "$jail" > "$backup/$jail.bans.after"
  comm -23 "$backup/$jail.bans.before" "$backup/$jail.bans.after" > "$backup/$jail.bans.lost"
  [[ ! -s $backup/$jail.bans.lost ]] || lost_bans=1
done
if (( lost_bans )); then
  echo 'reload removed a previously active ban; restoring prior configuration' >&2
  exit 1
fi

trap - EXIT
printf 'Fail2Ban rules active and verified; root-only snapshot: %s\n' "$backup"
REMOTE

scp -q -o BatchMode=yes "$local_tmp/install-remote.sh" "$target:$stage/install-remote.sh"
if ssh -o BatchMode=yes "$target" "chmod 0700 '$stage/install-remote.sh' && '$stage/install-remote.sh' '$stage' '$backup' && rm -rf -- '$stage'"; then
  :
else
  ssh -o BatchMode=yes "$target" "rm -rf -- '$stage'" || true
  exit 1
fi
