#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write

[[ ${NODE2_DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $NODE2_DOMAIN != *.example.com ]] || die 'set a real NODE2_DOMAIN in .env'
[[ ${LETSENCRYPT_EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && $LETSENCRYPT_EMAIL != admin@example.com ]] || die 'set a real LETSENCRYPT_EMAIL in .env'
[[ ${NODE2_XUI_PANEL_PATH:-} =~ ^[A-Za-z0-9_-]{16,96}$ && $NODE2_XUI_PANEL_PATH != replace-* ]] || die 'set a private random NODE2_XUI_PANEL_PATH in .env'
[[ ${NODE2_DNS_PANEL_PATH:-} =~ ^[A-Za-z0-9_-]{16,96}$ && $NODE2_DNS_PANEL_PATH != replace-* ]] || die 'set a private random NODE2_DNS_PANEL_PATH in .env'
[[ ${NODE2_DNS_ALLOWED_CIDR:-} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die 'NODE2_DNS_ALLOWED_CIDR must be an IPv4 CIDR'
[[ ${NODE2_PANEL_USER:-} =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 'set a valid NODE2_PANEL_USER in .env'
panel_password=${NODE2_PANEL_PASSWORD:-}
[[ ${#panel_password} -ge 20 && $panel_password != replace-* ]] || die 'set a 20+ character NODE2_PANEL_PASSWORD in .env'
web_root=${NODE2_WEB_ROOT:-/var/www/node2}
[[ $web_root =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'NODE2_WEB_ROOT must be an absolute simple path'
need_cmd ssh
need_cmd htpasswd
need_cmd mktemp

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
site_template="$repo_root/deploy/host/nginx/sites/terranex.conf.template"
bootstrap_template="$tmp/acme-bootstrap.conf"
site="$tmp/terranex.conf"
auth="$tmp/panel-auth"
[[ -f $site_template ]] || die 'active node2 Nginx template is missing'

sed \
  -e "s#__NODE2_DOMAIN__#$NODE2_DOMAIN#g" \
  -e "s#__XUI_PANEL_PATH__#$NODE2_XUI_PANEL_PATH#g" \
  -e "s#__DNS_PANEL_PATH__#$NODE2_DNS_PANEL_PATH#g" \
  -e "s#__DNS_ALLOWED_CIDR__#$NODE2_DNS_ALLOWED_CIDR#g" \
  "$site_template" > "$site"
printf '%s\n' "$panel_password" | htpasswd -niB -C 12 "$NODE2_PANEL_USER" > "$auth"

cat > "$bootstrap_template" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name $NODE2_DOMAIN cloud.$NODE2_DOMAIN ai.$NODE2_DOMAIN;
  root $web_root;
  location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
  location / { return 404; }
}
EOF

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes "$target" \
  "install -d -m 0755 '$web_root/.well-known/acme-challenge'; install -m 0644 /dev/stdin /etc/nginx/sites-available/node2-acme.conf; ln -sfn /etc/nginx/sites-available/node2-acme.conf /etc/nginx/sites-enabled/node2-acme.conf; nginx -t && systemctl reload nginx" < "$bootstrap_template"

for host in "$NODE2_DOMAIN" "cloud.$NODE2_DOMAIN" "ai.$NODE2_DOMAIN"; do
  ssh "$target" "certbot certonly --webroot -w '$web_root' -d '$host' --email '$LETSENCRYPT_EMAIL' --agree-tos --no-eff-email --non-interactive --keep-until-expiring"
done
ssh "$target" 'systemctl enable --now certbot.timer'

ssh "$target" 'install -d -m 0755 /etc/nginx/conf.d /etc/nginx/snippets /etc/nginx/sites-available /etc/nginx/sites-enabled /var/log/nginx/metrics /var/log/nginx/incident-correlation; setfacl -m u:doom:rx /var/log/nginx /var/log/nginx/metrics /var/log/nginx/incident-correlation; setfacl -d -m u:doom:r-X /var/log/nginx /var/log/nginx/metrics /var/log/nginx/incident-correlation; find /var/log/nginx -maxdepth 2 -type f -exec setfacl -m u:doom:r-- {} +'
ssh "$target" "install -m 0644 /dev/stdin /etc/nginx/nginx.conf" < "$repo_root/deploy/host/nginx/nginx.conf"
for file in "$repo_root"/deploy/host/nginx/conf.d/*.conf; do
  ssh "$target" "install -m 0644 /dev/stdin '/etc/nginx/conf.d/$(basename "$file")'" < "$file"
done
ssh "$target" 'install -m 0644 /dev/stdin /etc/nginx/snippets/proxy-common.conf' < "$repo_root/deploy/host/nginx/snippets/proxy-common.conf"
ssh "$target" 'install -m 0644 /dev/stdin /etc/nginx/sites-available/terranex.conf' < "$site"
ssh "$target" 'install -m 0600 /dev/stdin /etc/nginx/.panel-auth' < "$auth"
ssh "$target" 'set -e; install -d -m 0700 /etc/nginx/sites-disabled; if [[ -e /etc/nginx/sites-enabled/default ]]; then mv -f /etc/nginx/sites-enabled/default /etc/nginx/sites-disabled/default; fi; if [[ -e /etc/nginx/sites-enabled/node2-acme.conf ]]; then mv -f /etc/nginx/sites-enabled/node2-acme.conf /etc/nginx/sites-disabled/node2-acme.conf; fi; ln -sfn /etc/nginx/sites-available/terranex.conf /etc/nginx/sites-enabled/terranex.conf; nginx -t; systemctl reload nginx; systemctl enable --now fail2ban; fail2ban-client ping; if [[ -f /var/log/fail2ban.log ]]; then setfacl -m u:doom:r-- /var/log/fail2ban.log; fi'
"$(dirname "$0")/deploy-fail2ban.sh" "$target"
"$(dirname "$0")/deploy-node2-metrics.sh" "$target"
printf 'Node2 reverse proxy and TLS configured for %s, cloud.%s, and ai.%s.\n' "$NODE2_DOMAIN" "$NODE2_DOMAIN" "$NODE2_DOMAIN"
