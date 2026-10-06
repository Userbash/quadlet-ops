#!/usr/bin/env fish
set -l script_dir (dirname (status filename))
exec "$script_dir/bootstrap-node2-client.sh" $argv
