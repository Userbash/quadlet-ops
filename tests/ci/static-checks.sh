#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

profile=deploy/profiles/node2-full.units
while IFS= read -r unit; do
  [[ -z $unit || $unit == \#* ]] && continue
  if [[ $unit == dnsserver-quadlet ]]; then
    manifest=deploy/quadlet/node2/$unit.kube
  else
    manifest=deploy/quadlet/node2/$unit.container
  fi
  [[ -f $manifest ]] || { printf 'profile manifest missing: %s\n' "$manifest" >&2; exit 1; }
done < "$profile"

for wrapper in scripts/*.fish; do
  [[ $wrapper == scripts/check-local.fish ]] && continue
  target=$(sed -n 's/.*exec "\$script_dir\/\([^"]*\)".*/\1/p' "$wrapper")
  [[ -n $target && -f scripts/$target ]] || { printf 'invalid fish wrapper target: %s\n' "$wrapper" >&2; exit 1; }
  ! grep -Fq 'status dirname' "$wrapper" || { printf 'obsolete fish command substitution in %s\n' "$wrapper" >&2; exit 1; }
done

[[ -f deploy/host/nginx/conf.d/node2-metrics-log-format.conf ]]
[[ ! -e deploy/host/nginx/conf.d/nginx-metrics-log-format.conf ]]
grep -Fq 'deploy/host/nginx/conf.d/node2-metrics-log-format.conf' scripts/deploy-node2-metrics.sh

duplicates=$({
  awk '/^[[:space:]]*log_format[[:space:]]+/ {print $2}' deploy/host/nginx/nginx.conf
  awk '/^[[:space:]]*log_format[[:space:]]+/ {print $2}' deploy/host/nginx/conf.d/*.conf
} | sort | uniq -d)
[[ -z $duplicates ]] || { printf 'duplicate Nginx log_format names: %s\n' "$duplicates" >&2; exit 1; }

while IFS= read -r image; do
  [[ $image == localhost/* ]] && continue
  [[ $image == *@sha256:* ]] || { printf 'unpinned external image in node2 Quadlet: %s\n' "$image" >&2; exit 1; }
  digest=${image##*@sha256:}
  [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || { printf 'malformed image digest in node2 Quadlet: %s\n' "$image" >&2; exit 1; }
done < <(sed -n 's/^[[:space:]]*Image=//p' deploy/quadlet/node2/*)

if grep -hE '^[[:space:]]*PublishPort=' deploy/quadlet/node2/* | grep -Ev 'PublishPort=127\.0\.0\.1:'; then
  echo 'node2 Quadlet publishes a port outside loopback.' >&2
  exit 1
fi

echo 'Static repository invariants: OK'
