#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' 'deploy-node2.sh is kept for compatibility; use restore-node2.sh and validate-node2.sh.'
exec "$(dirname "$0")/restore-node2.sh" "$@"
