#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
domain=ci.invalid

install -D -m 0644 "$repo/deploy/host/nginx/nginx.conf" /etc/nginx/nginx.conf
install -d -m 0755 /etc/nginx/conf.d /etc/nginx/sites-enabled /var/log/nginx/metrics /var/log/nginx/incident-correlation /var/www/html
rm -f /etc/nginx/sites-enabled/default
cp -a "$repo"/deploy/host/nginx/conf.d/*.conf /etc/nginx/conf.d/
sed -e "s/__NODE2_DOMAIN__/$domain/g" \
  -e 's/__DNS_ALLOWED_CIDR__/127.0.0.1\/32/g' \
  -e 's/__XUI_PANEL_PATH__/ci-xui-panel/g' \
  -e 's/__DNS_PANEL_PATH__/ci-dns-panel/g' \
  "$repo/deploy/host/nginx/sites/terranex.conf.template" > /etc/nginx/sites-enabled/terranex.conf

for host in "$domain" "cloud.$domain" "ai.$domain"; do
  install -d -m 0755 "/etc/letsencrypt/live/$host"
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -subj "/CN=$host" -keyout "/etc/letsencrypt/live/$host/privkey.pem" \
    -out "/etc/letsencrypt/live/$host/fullchain.pem" >/dev/null 2>&1
done
htpasswd -bc /etc/nginx/.panel-auth ci-test ci-test-only >/dev/null
chmod 0644 /etc/nginx/.panel-auth

nginx -t
