#!/usr/bin/env fish
set -e
test (count $argv) -ge 2; or begin; echo 'usage: restore-node2.fish HOST BACKUP_DIR'; exit 2; end
exec (status dirname)/restore-node2.sh $argv
