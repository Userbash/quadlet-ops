# Quadlet Migration Record

## Purpose

This document records the target runtime model and the migration decisions for the Node2 service profile. It complements the operational [Quadlet guide](QUADLET.md), [deployment stages](DEPLOYMENT_STAGES.md), and [architecture overview](ARCHITECTURE.md).

## Runtime Model

Application and observability containers run as the unprivileged `doom` account through rootless Podman and Quadlet. Quadlet files are installed under `/home/doom/.config/containers/systemd/` and generated into user systemd services. User lingering keeps the service manager available across logout and reboot.

Host services remain under the host systemd manager:

| Service | Runtime | Responsibility |
|---|---|---|
| Nginx | Host systemd | Public HTTP/HTTPS edge, reverse proxy, ACME challenge and access logs |
| Fail2Ban | Host systemd | Reads selected Nginx logs and applies finite host firewall bans |
| Certbot | Host package and renewal timer | Requests and renews certificates |
| Podman API socket | `doom` user systemd | User-scoped API used by Portainer |

The Node2 Quadlet profile is explicitly listed in `deploy/profiles/node2-full.units`. It includes Portainer, 3X-UI, Nextcloud app/database/Redis/RabbitMQ/cron, DNS and its collectors, Open WebUI, Qdrant, Loki, Alloy, and VictoriaMetrics. Node1-only Alloy is stored separately and is not part of this profile.

## State and Images

Quadlet owns container lifecycle; each workload must have one lifecycle controller. Existing image layers remain in the `doom` user's Podman storage unless an operator explicitly removes them. A container can be recreated from its configured image while bind mounts and named volumes retain their state.

The manifests define persistent mounts for application state and explicitly named volumes where appropriate. Deployment configuration may be copied from this repository, but live database contents, uploads, DNS zones, private keys, credentials, and container storage are not part of the public project. A separate protected application-data backup is required for stateful workloads.

Images are pinned by version or digest where the deployment supports it. The 3X-UI build script checks out a fixed upstream commit and builds as `doom`; it does not rely on a pre-existing local image. Portainer is optional: its rootless Podman integration is best-effort and is not a supported security boundary.

## Service Mapping

| Workload | Quadlet definition | Notes |
|---|---|---|
| Portainer | `portainer.container` | Loopback HTTPS; persistent `portainer_data`; user Podman socket |
| 3X-UI | `3xui.container` | Locally built pinned image; persistent panel and certificate paths |
| Nextcloud | app, cron, PostgreSQL, Redis, RabbitMQ containers and a network | Existing data paths must be preserved when migrating an installation |
| DNS | `dnsserver-quadlet.kube` and collector containers | Pod networking preserves the proxy and DNS server relationship |
| Open WebUI | container and named volume | Persistent application state |
| Qdrant | `socraticode-qdrant.container` | Persistent named volume |
| Loki and Alloy | containers on the observability network | Logs and telemetry pipeline |
| VictoriaMetrics | `victoria-metrics.container` | Local time-series storage and query endpoint |

The exact image references, mounts, ports, resource limits, and ordering are defined by the Quadlet files. Review those files before changing a live installation; this summary is not a substitute for the manifests.

## Deployment and Verification

The deployment path is explicit rather than based on scanning all files under `deploy/`:

1. Bootstrap installs the OS packages, prepares the `doom` account and subordinate ID mappings, enables lingering, starts the rootless Podman socket, and enables host Nginx and Fail2Ban.
2. Stack deployment copies the selected Node2 manifests and service configuration, prepares required directories and generated secrets on the target, builds the pinned 3X-UI image, reloads the user systemd manager, and starts services in dependency order.
3. The stack checker verifies user-systemd and Podman state, then performs bounded readiness checks for services with defined health endpoints.
4. Web configuration is a separate, confirmed step after DNS is ready. It configures host Nginx, obtains certificates with Certbot, installs the selected Fail2Ban rules, then installs and verifies the metrics pipeline.
5. Validation is read-only. Backup, restore, and service activation remain separate operator actions.

Do not start a legacy Compose or hand-written systemd launcher for a workload after enabling its Quadlet service. Duplicate controllers can compete over container names, ports, and mounts.

## Migration Acceptance

Before treating a migration or fresh deployment as complete, verify:

- each container is owned by exactly one generated Quadlet service;
- the `doom` user manager is enabled through lingering and required services are enabled;
- expected images, mounts, networks, ports, and resource constraints are present;
- no duplicate containers or port conflicts exist;
- service-specific readiness checks pass, including database checks for Nextcloud;
- Nginx configuration validates and public routes return the expected responses;
- Fail2Ban loads the intended jails and reads the intended logs;
- Alloy and Loki are healthy, and VictoriaMetrics receives current samples when metrics are installed;
- no failed user units remain unexplained.

HTTP success alone does not establish data integrity. Stateful migrations also require application-level checks and a separately tested data backup.

## Rollback

Rollback one workload at a time. Stop the generated Quadlet service, restore its last reviewed unit or the documented prior controller, reload the appropriate systemd manager, and start only that controller. Do not remove or recreate named volumes or bind-mounted application data as part of a unit rollback. Verify service readiness and external routing before considering the rollback complete.

Host Nginx and Fail2Ban configuration have separate validation and restore procedures. A host configuration restore must be validated before reloading services. Provider firewall rules, DNS records, and application data are outside the Quadlet rollback path.

## Operational Boundaries

- The deployment scripts require explicit `DEPLOY_CONFIRM=YES` before host-changing operations.
- Scripts currently use root SSH for package and host-configuration management; application containers still run rootless as `doom`.
- Nginx and Fail2Ban are intentionally host services. Moving them into rootless containers would require a separately designed privileged-port and host-firewall boundary.
- The project includes configuration deployment and configuration-only backups, not a complete user-data backup system.
- Do not remove old images or rollback material until the operator has verified the migration and its recovery window.
