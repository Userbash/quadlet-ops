# Fail2Ban and metric response

## Observed state on Node2

The active Fail2Ban 1.0.2 configuration had 12 jails. Read-only regex checks against current and rotated logs confirmed these defects:

- `nginx-botsearch` watched an empty Nginx error log. Its filter did match requests when tested against the access log, but duplicated the more focused scanner jail.
- `nginx-empty-useragent` had no monitored file and its regex also matched one-to-three-character User-Agent values, not only empty values.
- `panel-dns-auth` watched the general access log while its target administrative traffic was written to the panel log. Its regex had zero matches in the tested rotation.
- `panel-rate` would ban on Nginx rate-limit events, including legitimate client throttling. It had no matches in the tested error-log rotation.
- `panel-slow` reused the authentication-failure filter and escalated six failures across a day to a seven-day ban.
- `xhttp-protection` expected an unrelated request shape and matched zero lines in the two tested XHTTP log generations. Generic protocol errors are not sufficient evidence to block a VPN client.
- Both old panel recidive jails used all-ports actions. Their custom filter matched zero of 19 existing ban events because it expected the jail and severity fields in the wrong order.
- The `agent-producer` filter treated 401, 403, 429, and 444 as equivalent. Those status codes have different meanings; a 429 or failed login alone must not be a long-term block signal.
- The XHTTP access log had no per-peer `limit_conn` decision, so aggregate rejection metrics could not be correlated to the source that crossed the existing Nginx guard.

Nginx has no configured real-IP forwarding header on this host, so the current access-log address is the TCP peer. The update preserves the host's existing global `ignoreip`; the new overlay does not copy or replace trusted addresses.

## Response stages

| Signal | Evidence and delay | Action | Scope |
|---|---|---|---|
| Repeated Nginx 444 denials | 8 events from one peer in 10 minutes | 30-minute temporary ban | TCP 80/443 only |
| Known web scanner paths | 3 exact scanner-pattern matches from one peer in 10 minutes | 1-hour temporary ban | TCP 80/443 only |
| Panel authentication failures | 8 HTTP 401/403 panel-log matches from one peer in 10 minutes; 429 is excluded | 30-minute temporary ban | TCP 80/443 only |
| XHTTP concurrency-limit abuse | 30 `limit_conn=REJECTED` log events from one peer in 5 minutes | 5-minute temporary ban | TCP 443 only |
| Repeated prior high-confidence bans | 3 selected-jail bans in 7 days | 1-day temporary ban | TCP 80/443 only |
| Persistent repeat offender | 5 selected-jail bans in 30 days | 7-day temporary ban | TCP 80/443 only |
| Panel rate-limit event | Nginx records 429; this is not proof of a bad password or hostile source | Keep Nginx's existing response; do not ban | No firewall change |
| XHTTP connection-limit event | More than 5% rejected requests for 3 one-minute checks, with sufficient traffic | Loki aggregates the XHTTP log by peer; Fail2Ban blocks only if one peer has 30 explicit rejections in 5 minutes | 5-minute TCP 443 ban; the Nginx limit itself is unchanged |
| Nginx connection-capacity pressure | Active connections exceed 70% of worker capacity for 3 checks | Cross-check stub_status, TCP backlog, SYN-RECV, conntrack, CPU/I/O wait, Loki source mix, and container samples | Alert and compare after 5 minutes; no firewall change |
| Nginx connection anomaly | Active connections exceed 5x the 24-hour baseline plus 100 after 2,500 samples, or reading connections exceed 2% of capacity | Classify alongside request/response bytes, peer concentration, upstream errors, and Fail2Ban activity | Alert only; large uploads and slow VPN peers are not automatically banned |
| TCP backlog pressure | More than 3 listen overflows or 10 listen drops in 5 minutes, or over 100 HTTPS SYN-RECV sockets, for 3 checks | Confirm against Nginx live connections and host metrics | Critical incident; no per-source block from aggregate counters |
| Nextcloud 5xx surge | More than 20% 5xx with at least 20 requests for 3 checks | Loki groups minimal Nextcloud source/status records and compares the next 5-minute window | Diagnose and track; 5xx alone never bans a file-sharing client |
| Host or application resource pressure | Fresh metrics must remain over/under threshold for 3 to 10 one-minute samples | Journal incident with nearby jail activity; no firewall block | No automatic tuning or cleanup |
| Container stopped | Fresh stopped-state metric for 2 to 3 checks and systemd unit is enabled and failed | One rootless systemd restart attempt; 30-minute cooldown | The one affected Quadlet service |

The recidive filters accept only ban events from the focused webscan and panel-auth jails. Both use finite bans and web ports. VPN ports are not included, and all-port recurrence actions are disabled. Nginx's existing request, connection, body-size, and timeout policies are not changed.

The XHTTP jail uses the public peer address. A 5-minute port 443 ban can also interrupt other HTTPS services for clients sharing that NAT address; the 30-event threshold and short duration limit this impact. The new jail is restricted to explicit XHTTP concurrency rejections and is not escalated by the recidive rules.

## Metrics guardrails

The metric watcher runs as rootless `doom`, not as root. Its only corrective operation is restarting an enabled, failed `nextcloud-app.service` or `3xui.service` after a fresh container-state series confirms the corresponding container is stopped. It never calls Fail2Ban or nftables and does not unblock clients. Nginx `stub_status` is bound to `127.0.0.1:9913`, with no public listener. The collector samples it every 30 seconds and combines it with kernel TCP, conntrack, host, container, and Loki data. For XHTTP incidents it asks Loki for temporary per-peer counts from `xhttp_access.log`; for Nextcloud 5xx and host/storage incidents it queries the short-retention `nginx_incident` stream. Query results are reduced to request/error/rejection totals, request/response byte totals, source count, and the largest source's share. The Nextcloud correlation log contains peer, status, request duration/size, response bytes, upstream time/status; it excludes URI, query string, cookies, other headers, and user-agent. Request length includes HTTP headers. IPs are not written to VictoriaMetrics, watcher state, or incident events.

An aggregate metric has no reliable client identity. Large file transfers, multiple VPN users behind one NAT, a shared client proxy, or a service-side failure can all produce the same aggregate symptom. Therefore only Fail2Ban's source-address log filters can block a client. VictoriaMetrics alerts can show per-jail activity, service errors, transfer sizes, request duration, and later recovery, but time overlap does not prove that a particular ban caused an improvement.

The first 24 hours only build the XHTTP and Nginx connection baselines. The corresponding surge alerts do not arm until enough samples exist. XHTTP rejection, XHTTP traffic-surge, Nextcloud 5xx, Nginx connection pressure, and host/storage incidents store a 5-minute Loki aggregate and compare it again after 5 minutes. The watcher also attaches live Nginx/TCP/conntrack, CPU/I/O wait, and container samples to incident events. For host/storage incidents it requires both request volume and combined request/response bytes to fall by at least 30% per service before calling the load reduced. If load does not fall, it refreshes peer concentration and recent Fail2Ban activity so a changed source pattern is visible without widening the block. A raw connection surge, SYN-RECV count, Nextcloud 5xx, or large transfer alone never bans a source. Other absolute thresholds are guard rails, require consecutive samples, and are alert-only. Repeated incident reminders are rate-limited to 15 minutes; these incident comparisons run every 5 minutes while active. A condition is resolved only after three consecutive clear samples. Missing/stale metrics suppress automatic recovery and report a telemetry incident.

## Apply and verify

The Fail2Ban updater stages and syntax-checks candidate config, tests each custom filter against positive/negative examples and live/rotated logs without printing matched lines, then reloads Fail2Ban and confirms the intended jail set and paths. The metrics deployment validates Alloy, the loopback-only Nginx status endpoint, privacy-minimized metrics and correlation logs, VictoriaMetrics readiness, and health/connection series before enabling the action timer.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2-metrics.sh node2
./scripts/deploy-fail2ban.sh node2
```

Both installers keep root-only snapshots under `/run` and restore the prior config if a validation or health check fails. They do not remove old backup files or old filter definitions; the obsolete jails are disabled so the installed behavior is unambiguous while rollback remains possible.

Inspect jail counters without showing banned addresses:

```fish
ssh root@node2 'fail2ban-client status'
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus systemctl --user list-timers node2-metric-actions.timer'
curl 'http://127.0.0.1:8428/api/v1/query?query=node2_fail2ban_jail_events_total%7Bevent%3D%22Ban%22%7D'
```

## Rollback

Restore the `jail.d/zzz-node2-automation.local` and `filter.d/node2-*.conf` files from the root-only snapshot and run `fail2ban-client -t` before `fail2ban-client reload`. Disable the metric response timer with the `doom` user manager; do not stop the metrics collector if its time series are still needed. Existing active ban sets remain managed by Fail2Ban and expire according to their configured finite ban times.
