#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
candidate=$(mktemp -d)
trap 'rm -rf "$candidate"' EXIT
cp -a /etc/fail2ban/. "$candidate/"
install -D -m 0644 "$repo/deploy/host/fail2ban/fail2ban-nginx.local" "$candidate/jail.d/zzz-node2-automation.local"
for filter in "$repo"/deploy/host/fail2ban/filter.d/*.conf; do
  install -D -m 0644 "$filter" "$candidate/filter.d/$(basename "$filter")"
done
fail2ban-client -c "$candidate" -t

stamp='06/Oct/2026:12:00:00 +0000'
matched_count() {
  local output count input=$1 filter=$2
  output=$(fail2ban-regex -c "$candidate" --verbosity 1 "$input" "$filter" 2>&1)
  count=$(awk '/^Lines:/ {if (match($0, /[0-9]+ matched/)) {v=substr($0, RSTART, RLENGTH); sub(/ matched/, "", v); print v; exit}}' <<< "$output")
  [[ $count =~ ^[0-9]+$ ]] || { echo 'Could not read synthetic Fail2Ban match count.' >&2; return 1; }
  printf '%s\n' "$count"
}
assert_match() {
  local filter=$1 expected=$2 input=$3 actual
  actual=$(matched_count "$input" "$filter")
  if [[ $expected == positive && $actual -eq 0 ]] || [[ $expected == negative && $actual -ne 0 ]]; then
    printf 'Fail2Ban %s synthetic test failed for filter %s.\n' "$expected" "$filter" >&2
    exit 1
  fi
}
assert_match node2-edge-deny positive '203.0.113.10 - - ['"$stamp"'] "GET / HTTP/1.1" 444 0 "-" "ci-probe"'
assert_match node2-edge-deny negative '203.0.113.10 - - ['"$stamp"'] "GET / HTTP/1.1" 429 0 "-" "ci-client"'
assert_match node2-webscan positive '203.0.113.10 - - ['"$stamp"'] "GET /.env HTTP/1.1" 404 0 "-" "ci-probe"'
assert_match node2-webscan negative '203.0.113.10 - - ['"$stamp"'] "GET /status.php HTTP/1.1" 404 0 "-" "ci-client"'
assert_match node2-panel-auth positive '203.0.113.10 - - ['"$stamp"'] "POST / HTTP/1.1" status=401'
assert_match node2-panel-auth negative '203.0.113.10 - - ['"$stamp"'] "POST / HTTP/1.1" status=429'
assert_match node2-xhttp-overlimit positive '203.0.113.10 [2026-10-06T09:10:00+00:00] "GET / HTTP/1.1" method=GET status=503 limit_conn=REJECTED bytes=0'
assert_match node2-xhttp-overlimit negative '203.0.113.10 [2026-10-06T09:10:00+00:00] "GET / HTTP/1.1" method=GET status=200 limit_conn=PASSED bytes=0'
assert_match node2-recidive positive '2026-10-06 12:00:00,000 fail2ban.actions [123]: NOTICE [nginx-webscan] Ban 203.0.113.10'
assert_match node2-recidive negative '2026-10-06 12:00:00,000 fail2ban.actions [123]: NOTICE [agent-producer] Ban 203.0.113.10'
echo 'Fail2Ban configuration and synthetic filter inputs: OK'
