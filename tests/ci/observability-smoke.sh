#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
alloy_image=docker.io/grafana/alloy:v1.10.2@sha256:bcf27f18c4402869af112fb39e35e1db3804a404686f4caa20bdf77814219223
loki_image=docker.io/grafana/loki:3.7.8@sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193

validate() {
  podman run --rm -v "$repo/deploy/config/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
    "$alloy_image" validate /etc/alloy/config.alloy
  podman run --rm -v "$repo/deploy/config/alloy/node2-metrics.alloy:/etc/alloy/node2-metrics.alloy:ro" \
    "$alloy_image" validate /etc/alloy/node2-metrics.alloy
}

integration() {
  temp=$(mktemp -d)
  network=ci-observability-$RANDOM
  loki=ci-loki-$RANDOM
  alloy=ci-alloy-$RANDOM
  loki_volume=ci-loki-data-$RANDOM
  alloy_volume=ci-alloy-data-$RANDOM
  cleanup() {
    podman rm -f "$alloy" "$loki" >/dev/null 2>&1 || true
    podman network rm "$network" >/dev/null 2>&1 || true
    podman volume rm -f "$alloy_volume" "$loki_volume" >/dev/null 2>&1 || true
    rm -rf "$temp"
  }
  trap cleanup EXIT
  podman network create "$network" >/dev/null
  podman volume create "$loki_volume" >/dev/null
  podman volume create "$alloy_volume" >/dev/null
  podman run -d --name "$loki" --network "$network" -p 127.0.0.1:13100:3100 \
    -v "$repo/deploy/config/loki/loki-config.yaml:/etc/loki/config.yaml:ro" \
    -v "$loki_volume:/loki" "$loki_image" -config.file=/etc/loki/config.yaml >/dev/null

  ready=0
  for _ in $(seq 1 60); do
    if curl --fail --silent http://127.0.0.1:13100/ready >/dev/null; then ready=1; break; fi
    sleep 2
  done
  [[ $ready == 1 ]] || { echo 'Loki did not become ready within 120 seconds.' >&2; podman logs "$loki" >&2; return 1; }

  printf 'logging { level = "info" }\n\nloki.write "ci" {\n  endpoint { url = "http://%s:3100/loki/api/v1/push" }\n}\n\nlocal.file_match "ci" {\n  path_targets = [{ __path__ = "/tmp/ci.log", job = "ci_smoke" }]\n}\n\nloki.source.file "ci" {\n  targets = local.file_match.ci.targets\n  forward_to = [loki.write.ci.receiver]\n}\n' "$loki" > "$temp/ci.alloy"
  smoke_id="ci-smoke-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  : > "$temp/ci.log"
  podman run -d --name "$alloy" --network "$network" \
    -v "$temp/ci.alloy:/etc/alloy/config.alloy:ro" -v "$temp/ci.log:/tmp/ci.log:ro" \
    -v "$alloy_volume:/var/lib/alloy/data" \
    "$alloy_image" run /etc/alloy/config.alloy --storage.path=/var/lib/alloy/data >/dev/null
  printf '%s\n' "$smoke_id" >> "$temp/ci.log"

  found=0
  for _ in $(seq 1 60); do
    end=$(date +%s%N)
    start=$((end - 300000000000))
    result=$(curl --fail --silent --get --data-urlencode 'query={job="ci_smoke"}' \
      --data-urlencode 'limit=10' --data-urlencode "start=$start" --data-urlencode "end=$end" \
      --data-urlencode 'direction=backward' http://127.0.0.1:13100/loki/api/v1/query_range 2>/dev/null || true)
    if [[ $result == *"$smoke_id"* ]]; then found=1; break; fi
    sleep 2
  done
  [[ $found == 1 ]] || { echo 'Alloy sample was not queryable from Loki within 120 seconds.' >&2; podman logs "$alloy" >&2; podman logs "$loki" >&2; return 1; }
  echo 'Isolated Alloy-to-Loki log ingestion: OK'
}

case "${1:-}" in
  validate) validate ;;
  integration) integration ;;
  *) echo 'usage: observability-smoke.sh validate|integration' >&2; exit 2 ;;
esac
