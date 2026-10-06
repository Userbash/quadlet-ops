#!/usr/bin/env bash
set -Eeuo pipefail

repo=https://github.com/MHSanaei/3x-ui.git
tag=v3.9.0
expected_commit=3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb
build_root=${XDG_CACHE_HOME:-$HOME/.cache}/node2-build/3x-ui-v3.9.0

command -v git >/dev/null || { echo 'git is required to build 3x-ui' >&2; exit 1; }
command -v podman >/dev/null || { echo 'rootless Podman is required to build 3x-ui' >&2; exit 1; }
[[ $(id -un) == doom ]] || { echo 'run this script as the unprivileged doom account' >&2; exit 1; }

install -d -m 0750 "$(dirname "$build_root")"
if [[ ! -d $build_root/.git ]]; then
  git clone --no-checkout "$repo" "$build_root"
fi
git -C "$build_root" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
actual_commit=$(git -C "$build_root" rev-parse "$tag^{commit}")
[[ $actual_commit == "$expected_commit" ]] || {
  printf '3x-ui tag commit mismatch: expected %s, got %s\n' "$expected_commit" "$actual_commit" >&2
  exit 1
}
git -C "$build_root" checkout --detach "$expected_commit"
podman build --pull=always --tag localhost/3x-ui:3.9.0 "$build_root"
podman image exists localhost/3x-ui:3.9.0
