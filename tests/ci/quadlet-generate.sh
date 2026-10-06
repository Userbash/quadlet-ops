#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
generator=$(command -v podman-system-generator || true)
if [[ -z $generator ]]; then
  for candidate in /usr/lib/systemd/system-generators/podman-system-generator /usr/libexec/podman/quadlet; do
    [[ -x $candidate ]] && generator=$candidate && break
  done
fi
[[ -x $generator ]] || { echo 'Podman Quadlet system generator not found.' >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$repo"/deploy/quadlet/node2/* "$stage/"
install -m 0644 "$repo/deploy/quadlet/node2/dnsserver-kube.yaml" "$stage/dnsserver-kube.yaml"
sed -i "s|/home/doom/dnsserver-kube.yaml|$stage/dnsserver-kube.yaml|" "$stage/dnsserver-quadlet.kube"
QUADLET_UNIT_DIRS="$stage" "$generator" --user --dryrun
echo 'Quadlet manifests generated; no containers or systemd services were started.'
