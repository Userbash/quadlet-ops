# Архитектура

Проект следует KISS: backup читает сервер, restore переносит проверенные архивы, validate не меняет состояние, activate выполняет ограниченный набор изменений после явного флага.

```text
оператор -> SSH -> bootstrap / restore / validate / activate
                    -> systemd -> Nginx -> приложения
                    -> Fail2Ban -> nftables
                    -> Alloy -> Loki
```

## Границы

- Nginx и Fail2Ban являются host-сервисами.
- Alloy и Loki запускаются rootless Podman-пользователем `doom`.
- Backup конфигураций не является backup данных приложений.
- Логи и базы не публикуются и не входят в Git.

## Поток загрузок

`/downloads/` получает отдельный JSON access-log. Поля `$http_range` и `$sent_http_content_range` сохраняются как structured metadata Alloy/Loki, а не как Loki labels, чтобы не создать высокую кардинальность.

## Идемпотентность

Bootstrap использует `apt-get` и `install -d`, повторный запуск безопасен. Restore заменяет конфигурации архивом, поэтому сначала нужен backup и проверка. Activate не запускается без `DEPLOY_CONFIRM=YES`.
