#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
need_cmd ssh
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" 'bash -s' < "$(dirname "$0")/bootstrap-node2.sh"
