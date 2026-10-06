#!/usr/bin/env fish
set -l script_dir (dirname (status filename))
exec "$script_dir/validate-node2.sh" $argv
