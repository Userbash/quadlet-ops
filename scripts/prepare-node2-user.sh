#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(id -un) == doom ]] || { echo 'run this script as the unprivileged doom account' >&2; exit 1; }
[[ ${NODE2_DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo 'NODE2_DOMAIN is required' >&2; exit 1; }

install -d -m 0750 \
  /home/doom/.config/containers/systemd \
  /home/doom/.config/systemd/user \
  /home/doom/bin \
  /home/doom/observability/bin \
  /home/doom/nextcloud/{app,data,config,custom_apps,db,redis,rabbitmq} \
  /home/doom/3x-ui/{db,cert,acme} \
  /home/doom/dns-config \
  /home/doom/dns-logs \
  /home/doom/dns-stats \
  /home/doom/portainer/data \
  /home/doom/.local/state/node2-metrics \
  /home/doom/.local/state/node2-metric-actions

if [[ ! -s /home/doom/nextcloud/.env ]]; then
  umask 077
  db_password=$(openssl rand -hex 32)
  admin_password=$(openssl rand -hex 24)
  redis_password=$(openssl rand -hex 32)
  rabbitmq_password=$(openssl rand -hex 32)
  app_secret=$(openssl rand -hex 32)
  cat > /home/doom/nextcloud/.env <<EOF
TZ=UTC
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=$db_password
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$admin_password
REDIS_PASSWORD=$redis_password
REDIS_HOST_PASSWORD=$redis_password
RABBITMQ_USER=nextcloud
RABBITMQ_PASSWORD=$rabbitmq_password
NEXTCLOUD_SECRET=$app_secret
EOF
  printf 'Nextcloud administrator: admin\nPassword: %s\n' "$admin_password" > /home/doom/nextcloud/admin-credentials.txt
fi
chmod 0600 /home/doom/nextcloud/.env
[[ ! -s /home/doom/nextcloud/admin-credentials.txt ]] || chmod 0600 /home/doom/nextcloud/admin-credentials.txt

cat > /home/doom/nextcloud/site.env <<EOF
NEXTCLOUD_TRUSTED_DOMAINS=cloud.$NODE2_DOMAIN
OVERWRITEHOST=cloud.$NODE2_DOMAIN
EOF
chmod 0600 /home/doom/nextcloud/site.env
printf 'NODE2_DOMAIN=%s\n' "$NODE2_DOMAIN" > /home/doom/observability/node2.env
chmod 0644 /home/doom/observability/node2.env

[[ -e /home/doom/nextcloud/php.ini ]] || install -m 0644 /dev/null /home/doom/nextcloud/php.ini
[[ -e /home/doom/bin/redis-entrypoint.sh ]] || install -m 0755 /dev/null /home/doom/bin/redis-entrypoint.sh
[[ -e /home/doom/observability/technitium.env ]] || install -m 0600 /dev/null /home/doom/observability/technitium.env
