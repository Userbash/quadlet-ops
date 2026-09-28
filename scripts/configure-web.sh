#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
target=$(ssh_target "${1:-${NODE2_HOST:-node2}}")
confirm_write
[[ ${NODE2_DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ${NODE2_DOMAIN} != *.example.com ]] || die 'NODE2_DOMAIN must be a real DNS name, not the example value'
[[ ${LETSENCRYPT_EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && ${LETSENCRYPT_EMAIL} != admin@example.com ]] || die 'LETSENCRYPT_EMAIL must be a real address, not the example value'
web_root=${NODE2_WEB_ROOT:-/var/www/node2}
[[ $web_root =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'NODE2_WEB_ROOT must be an absolute simple path'
need_cmd ssh
template=$(dirname "$0")/../deploy/nginx-node2.conf
bootstrap_template=$(dirname "$0")/../deploy/nginx-node2-bootstrap.conf
fail2ban=$(dirname "$0")/../deploy/fail2ban-nginx.local
[[ -f $template && -f $bootstrap_template && -f $fail2ban ]] || die 'web configuration templates are missing'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -e "s#__NODE2_DOMAIN__#${NODE2_DOMAIN}#g" -e "s#__NODE2_WEB_ROOT__#${web_root}#g" "$template" > "$tmp/nginx-node2.conf"
sed -e "s#__NODE2_DOMAIN__#${NODE2_DOMAIN}#g" -e "s#__NODE2_WEB_ROOT__#${web_root}#g" "$bootstrap_template" > "$tmp/nginx-node2-bootstrap.conf"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" "install -d -m 0755 '$web_root' '$web_root/.well-known/acme-challenge'; install -m 0644 /dev/stdin /etc/nginx/sites-available/node2.conf; ln -sfn /etc/nginx/sites-available/node2.conf /etc/nginx/sites-enabled/node2.conf; rm -f /etc/nginx/sites-enabled/default; nginx -t; systemctl reload nginx" < "$tmp/nginx-node2-bootstrap.conf"
ssh -o BatchMode=yes "$target" "certbot certonly --webroot -w '$web_root' -d '$NODE2_DOMAIN' --email '$LETSENCRYPT_EMAIL' --agree-tos --no-eff-email --non-interactive --keep-until-expiring"
ssh -o BatchMode=yes "$target" "install -m 0644 /dev/stdin /etc/nginx/sites-available/node2.conf; nginx -t; systemctl reload nginx" < "$tmp/nginx-node2.conf"
ssh -o BatchMode=yes "$target" "install -m 0644 /dev/stdin /etc/fail2ban/jail.d/node2-nginx.local; nginx -t; systemctl reload nginx; systemctl enable --now fail2ban; fail2ban-client ping" < "$fail2ban"
printf 'Nginx, Let\x27s Encrypt, and Fail2Ban configured for %s on %s.\n' "$NODE2_DOMAIN" "$target"
