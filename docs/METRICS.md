# Node2 workload metrics

## Scope

The metrics path adds aggregate observability for file transfers through Nextcloud and VLESS/XHTTP without changing the active Nginx rate limits, body-size limits, proxy buffering, or timeout values. Nginx writes a separate JSON access log containing status, elapsed time, request bytes, response bytes, and existing limit decisions. It deliberately omits request paths, query strings, client addresses, cookies, user agents, and referrers.

Alloy reads those files and turns them into counters and histograms. A rootless `doom` user timer samples host CPU, I/O wait, memory, load, root filesystem capacity, Nextcloud's actual data filesystem, Nextcloud HTTP readiness, CPU/memory use of the Nextcloud and 3X-UI containers, and TCP/Nginx connection state every 30 seconds. A loopback-only Nginx `stub_status` listener reports active, reading, writing, waiting, accepted, handled, and total request counts. Linux TCP listen drops/overflows, SYN-RECV and established HTTPS sockets, and conntrack occupancy are sampled alongside it. Access-log sampling still describes completed request duration and size; `stub_status` supplies the concurrent connection view.

VictoriaMetrics runs as a rootless Quadlet container bound to `127.0.0.1:8428`, stores the time series in its named volume, and retains 90 days. Alloy remote-writes metrics to it and continues to send the small capacity snapshots to Loki for cross-checking. This adds a local query endpoint, not a public service or dashboard.

## Main series

- `node2_nginx_http_requests_total`: completed requests, labelled by service, status, and the Nginx limit decisions.
- `node2_nginx_request_duration_seconds_bucket`: completed request duration histograms.
- `node2_nginx_request_body_bytes_bucket` and `node2_nginx_response_body_bytes_bucket`: transfer-size histograms. Request bytes include HTTP headers as reported by Nginx.
- `node2_cpu_busy_ratio`, `node2_memory_available_bytes`, `node2_load1`: host pressure.
- `node2_root_filesystem_used_bytes` and `node2_root_filesystem_available_bytes`: root filesystem capacity.
- `node2_nextcloud_filesystem_used_bytes` and `node2_nextcloud_filesystem_available_bytes`: capacity of the filesystem backing Nextcloud's data directory.
- `node2_nextcloud_application_container_cpu_ratio`, `node2_nextcloud_application_container_memory_bytes`, and corresponding `node2_xui_container_*` series: container consumption. CPU ratio is the fraction of one CPU as reported by Podman, so it can exceed 1 on a multi-core workload.
- `node2_nextcloud_http_status_up`, `node2_nextcloud_storage_scrape_success`, `node2_nextcloud_application_container_running`, `node2_nextcloud_application_container_stats_up`, `node2_xui_container_running`, and `node2_xui_container_stats_up`: health/sample validity indicators. Container running state comes from `podman inspect`; a failed resource-stat sample is tracked separately and never interpreted as a stopped container.
- `node2_nginx_status_up`, `node2_nginx_active_connections`, `node2_nginx_reading_connections`, `node2_nginx_writing_connections`, and `node2_nginx_waiting_connections`: Nginx live connection states. `node2_nginx_connection_capacity` is worker count multiplied by the currently configured 8192 `worker_connections` per worker.
- `node2_nginx_accepted_connections_total`, `node2_nginx_handled_connections_total`, and `node2_nginx_requests_total`: Nginx cumulative stub-status counters.
- `node2_nginx_established_443_connections` and `node2_nginx_syn_recv_443_connections`: current TCP sockets for the public HTTPS listener.
- `node2_tcp_listen_overflows_total`, `node2_tcp_listen_drops_total`, `node2_tcp_syncookies_sent_total`, and `node2_tcp_backlog_drops_total`: kernel TCP pressure counters. They are cumulative gauges, so use `increase()` or `rate()` to inspect changes.
- `node2_conntrack_entries` and `node2_conntrack_limit`: current conntrack occupancy and maximum, when the kernel exposes these files.
- `node2_cpu_iowait_ratio`: sampled I/O wait share, separate from CPU busy ratio.
- `node2_fail2ban_jail_events_total`: Fail2Ban `Ban`, `Unban`, `Restore Ban`, and `Found` activity grouped by configured jail and event. Source IPs are never added to this metric.

There are no labels derived from unbounded client input such as URI, IP, session, or arbitrary headers. This keeps the series set bounded and avoids putting access tokens into metrics.

## Queries

Use the local VictoriaMetrics API. Examples below use `curl` in fish syntax:

```fish
curl 'http://127.0.0.1:8428/api/v1/query?query=node2_nextcloud_filesystem_available_bytes'
curl 'http://127.0.0.1:8428/api/v1/query?query=rate(node2_nginx_http_requests_total%7Bservice%3D%22xhttp%22%7D%5B5m%5D)'
curl 'http://127.0.0.1:8428/api/v1/query?query=histogram_quantile(0.95%2C%20sum%20by%20(le)%20(rate(node2_nginx_request_duration_seconds_bucket%7Bservice%3D%22nextcloud%22%7D%5B1h%5D)))'
curl 'http://127.0.0.1:8428/api/v1/query?query=rate(node2_nginx_request_body_bytes_sum%7Bservice%3D%22nextcloud%22%7D%5B1h%5D)'
curl 'http://127.0.0.1:8428/api/v1/query?query=node2_nginx_active_connections'
curl 'http://127.0.0.1:8428/api/v1/query?query=node2_nginx_reading_connections%20%2F%20clamp_min(node2_nginx_connection_capacity%2C1)'
curl 'http://127.0.0.1:8428/api/v1/query?query=increase(node2_tcp_listen_drops_total%5B5m%5D)'
curl 'http://127.0.0.1:8428/api/v1/query?query=node2_conntrack_entries%20%2F%20clamp_min(node2_conntrack_limit%2C1)'
```

The request rate and size distributions make it possible to compare ordinary and peak windows before changing any limit. A rise in 4xx/5xx status counts, duration, or container resource use can be inspected alongside available storage. Do not lower limits based on one short sample; use representative sync, WebDAV, chunked-upload, VPN NAT, and peak periods.

## Automated response

`node2-metric-actions.timer` evaluates fresh samples once per minute. A missing or older-than-three-minutes telemetry sample makes the watcher hold all service decisions and emit a telemetry incident after two checks. Each condition must remain true for consecutive samples: 3 for service readiness and critical Nginx/TCP pressure, 5 for CPU/I/O-wait/memory pressure, 10 for low storage, and 3 for request-error, connection-rejection, or traffic-spike signals. An active incident is repeated at most every 15 minutes and is marked recovered after 3 clear samples.

Connection anomaly signals are:

- Nginx status unavailable for 3 checks: critical telemetry/service incident.
- Active connections over 70% of measured worker capacity for 3 checks: connection-capacity warning.
- Active connections over 5 times the rolling 24-hour mean plus 100, after at least 2500 samples, for 3 checks: baseline surge warning. This rule needs about 21 hours of 30-second samples before it arms.
- Reading connections over 2% of worker capacity for 5 checks: slow/incomplete request or upload warning. This does not distinguish abusive slow headers from legitimate large uploads by itself.
- At least 4 listen overflows, 11 listen drops in 5 minutes, or more than 100 HTTPS SYN-RECV sockets for 3 checks: TCP backlog pressure incident.
- Conntrack above 80% for 3 checks and host I/O wait above 20% for 5 checks: resource pressure warnings.

These global signals are alert-only. On each opening and five-minute follow-up, the watcher attaches aggregate Nginx/TCP, CPU/I/O, conntrack, container, Loki source-concentration, and Fail2Ban activity context. It compares request counts and total request/response bytes with the preceding five-minute window. If pressure remains, the next incident update refreshes the same summaries; it does not widen a ban. The only connection-metric-driven client block remains the specific XHTTP rule: 30 logged `limit_conn=REJECTED` events from the same peer in five minutes, blocked on TCP 443 for five minutes. Other narrow Fail2Ban jails handle verified scanner and panel-auth patterns.

The watcher has a narrow recovery action: it asks the `doom` user systemd manager to restart Nextcloud or 3X-UI only when the corresponding container is confirmed stopped, its Quadlet unit is enabled and `failed`, metrics are fresh, and the 30-minute recovery cooldown has elapsed. It does not restart a running container because of high CPU, low disk, HTTP errors, large uploads, a traffic surge, or VPN connection rejections. Create `/home/doom/.local/state/node2-metric-actions/MAINTENANCE` before a planned stop to suppress automated recovery, then remove it when maintenance is complete.

Metrics remain aggregate by service and never carry client IP labels. When an XHTTP incident opens, the watcher queries Loki's `xhttp_access.log`; for Nextcloud 5xx, Nginx connection, and host/storage incidents it queries the short-retention `nginx_incident` stream and XHTTP stream. It groups transiently by peer and records only totals, request/response bytes, source count, top-source share, upstream-error summaries, live connection state, TCP counters, resource context, and recent Fail2Ban activity; it never persists or emits source addresses. The Nextcloud correlation log contains peer, status, request duration/size, response bytes, upstream time/status, with no URI, query, cookies, other headers, or user-agent, and rotates after 7 days. It compares requests and both directions of bytes every 5 minutes; a host/storage load is called reduced only when both request volume and combined bytes fall by at least 30% for the relevant services. This time correlation does not prove a specific ban caused the change.

Fail2Ban blocks XHTTP peers only after 30 explicit `limit_conn=REJECTED` events from the same address within 5 minutes, for 5 minutes on TCP 443. Nginx's existing per-peer connection cap is unchanged. A total traffic surge or a high Nextcloud 5xx rate triggers Loki correlation but does not trigger an address ban by itself: a busy VPN peer can be legitimate, and Nextcloud 5xx can be a backend fault. Other address bans continue to use the validated scanner/authentication filters. See [SECURITY_AUTOMATION.md](SECURITY_AUTOMATION.md) for the response stages.

## Install and validate

The installer has an explicit write guard and is intended to be run after reviewing the staged Nginx status listener, collector, and Alloy changes:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2-metrics.sh node2
```

It validates the Nginx patches, logrotate rules, and Alloy configuration before activation, then checks Nextcloud and the AI endpoint, Alloy, VictoriaMetrics, and arrival of a health series. It leaves a root-only rollback snapshot under `/run/node2-metrics-*`. The metrics log excludes request paths and client identity; the separate Nextcloud correlation log contains only peer, status, and duration. Metrics logs retain up to 14 days and the correlation log up to 7 days.

The capacity collector is a rootless user service/timer and writes no credentials or request data. Its first CPU ratio sample is marked invalid because a delta requires two readings. If Podman cannot return container stats or Nextcloud's data mount is unavailable, corresponding `*_up` metrics go to zero and values are reported as zero instead of being presented as valid measurements.

## Retention and disk

VictoriaMetrics retains 90 days in its dedicated named volume. Monitor the host filesystem metrics to ensure this retention remains affordable. Privacy-minimized metrics logs rotate after 14 days or at 20 MiB; the minimal source-correlation log rotates after 7 days or at 20 MiB. The nested log directories are not included in the existing Nginx log glob, preventing duplicate ingestion of the more detailed original logs.

## Official references

- [Grafana Alloy `loki.process`](https://grafana.com/docs/alloy/v1.10/reference/components/loki/loki.process/)
- [Grafana Alloy `prometheus.scrape`](https://grafana.com/docs/alloy/v1.10/reference/components/prometheus/prometheus.scrape/)
- [Grafana Alloy `prometheus.remote_write`](https://grafana.com/docs/alloy/v1.10/reference/components/prometheus/prometheus.remote_write/)
- [VictoriaMetrics single-node](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/)
