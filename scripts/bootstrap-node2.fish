#!/usr/bin/env fish
set -e
bash -c 'set -a; test -f .env && . ./.env; set +a; exec "$@"' -- bash (status dirname)/bootstrap-node2-client.sh $argv
