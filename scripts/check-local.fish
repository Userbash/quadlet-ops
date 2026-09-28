#!/usr/bin/env fish
set -l required git ssh bash tar sha256sum
for command in $required
    command -q $command; or begin
        echo "missing command: $command" >&2
        exit 1
    end
end
if test -e .env
    test (stat -c '%a' .env) = 600; or echo 'warning: .env should have mode 600' >&2
end
echo 'local prerequisites: OK'
