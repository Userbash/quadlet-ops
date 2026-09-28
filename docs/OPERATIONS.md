# Эксплуатация

## Ежедневный backup

```fish
./scripts/backup-node2.fish node2
```

Архив создаётся в `backups/node2-UTC_TIMESTAMP`. Перед передачей храните его в зашифрованном хранилище.

## Восстановление

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/restore-node2.fish node2 backups/node2-YYYYmmddTHHMMSSZ
./scripts/validate-node2.fish node2
set -lx DEPLOY_CONFIRM YES
./scripts/activate-node2.fish node2
```

Restore не перезапускает сервисы. Activate делает `nginx reload`, перезапускает Fail2Ban и поднимает observability через Podman Compose.

## Диагностика

```fish
ssh node2 'nginx -t; fail2ban-client status; systemctl status nginx fail2ban'
ssh node2 'journalctl -u fail2ban --since "24 hours ago"'
```
