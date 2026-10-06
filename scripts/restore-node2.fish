#!/usr/bin/env fish
set -e
test (count $argv) -ge 2; or begin; echo 'usage: restore-node2.fish HOST BACKUP_DIR'; exit 2; end
set -l script_dir (dirname (status filename))
exec "$script_dir/restore-node2.sh" $argv
