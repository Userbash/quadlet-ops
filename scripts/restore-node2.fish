#!/usr/bin/env fish
set -e
test (count $argv) -ge 2; or begin; echo 'usage: restore-node2.fish HOST BACKUP_DIR'; exit 2; end
bash -c 'set -a; test -f .env && . ./.env; set +a; exec "$@"' -- bash (status dirname)/restore-node2.sh $argv
