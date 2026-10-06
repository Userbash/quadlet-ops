# Node2 Quadlet Ops

Node2 Quadlet Ops prepares and maintains a Debian or Ubuntu server with host Nginx/Fail2Ban and rootless Podman Quadlet services owned by `doom`. The explicit `node2-full` profile includes Portainer, 3X-UI, Nextcloud, DNS, Open WebUI, Qdrant, Loki, Alloy, VictoriaMetrics, and metric collection.

**Suggested GitHub repository:** `quadlet-ops`

**GitHub description:** `Rootless Podman Quadlet deployment and operations for Node2, with Nginx, Fail2Ban, monitoring, and configuration backups.`

The project is deliberately plain: SSH, shell scripts, systemd, Quadlet, and text configuration. Every command that writes to a server requires `DEPLOY_CONFIRM=YES`. Bootstrap does not configure SSH, DNS, or firewall policy; the separate web stage obtains TLS certificates after DNS is ready.

## Capabilities

- Installs Nginx, Fail2Ban, Podman, and rootless-container prerequisites on Debian or Ubuntu.
- Creates the unprivileged `doom` service account, provisions subordinate UID/GID ranges, enables a lingering user systemd manager, and starts the rootless Podman socket.
- Deploys a node2-only Quadlet profile from `deploy/quadlet/node2/`; node1 Alloy and duplicate Portainer definitions are not selected.
- Builds 3X-UI 3.9.0 from a pinned upstream commit as `doom`, since the live `localhost` image is not present on a clean VPS.
- Installs Alloy, Loki, Nextcloud PHP/Redis settings, DNS collector code, and user systemd metric jobs without copying application databases or user files.
- Provides staged bootstrap, stack deployment, verification, backup, and rollback procedures in [Deployment Stages](docs/DEPLOYMENT_STAGES.md).
- Configures an Nginx download site, JSON range-aware access logs, Certbot/Let's Encrypt certificates, and Fail2Ban jails after DNS is ready.
- Enables unattended security-only APT updates; normal package updates and container image updates remain explicit operations.
- Creates timestamped server backups and SHA-256 manifests; validates the manifest before restore.
- Restores reviewed configuration separately from service activation.
- Runs read-only Nginx, Fail2Ban, Quadlet service, and Alloy validation where their configuration is present.
- Keeps the host-level and container-level responsibilities separate: Nginx and Fail2Ban run on the host; containers run as `doom`.
- Runs shell checks, scans public files for obvious secrets, and packages a public bundle in GitHub Actions.

## Important Limits

- Portainer manages Podman through Podman's Docker-compatible API. Portainer's current documentation says rootless Podman may work but is not officially supported, and its documented supported baseline is rootful Podman 5 on CentOS 9. This project's Debian/Ubuntu plus rootless setup is therefore an optional, best-effort Portainer configuration, not a vendor-supported combination. See [Portainer's Podman requirements](https://docs.portainer.io/admin/environments/add/podman) and [Podman socket instructions](https://docs.portainer.io/admin/environments/add/podman/socket).
- The Portainer listener binds to `127.0.0.1:9443`. Reach it through an SSH tunnel unless you deliberately configure a reviewed TLS reverse proxy.
- A clean deployment generates new Nextcloud credentials and empty service data directories. User databases, uploads, DNS zones, Portainer state, 3X-UI database/certificates, TLS private keys, API tokens, and `.env` files are never copied from node2.
- The 3X-UI admin base path must be aligned with `NODE2_XUI_PANEL_PATH` after first-run setup; the live panel database is intentionally excluded. DNS-panel access defaults to loopback until a trusted CIDR is configured.
- Backups do not include live database contents, user uploads, or container storage. Define a separate tested backup and retention plan for application data.
- Firewall rules, SSH policy, DNS, TLS issuance, and cloud-provider networking are intentionally not changed by scripts.

## Requirements

On the operator machine: Git, fish, Bash, OpenSSH client, tar, and `sha256sum`. The operator must be able to connect to the target using a key without an interactive password prompt.

On the target: a clean Debian or Ubuntu host using systemd, root SSH access, and network access to distribution repositories and container registries. Confirm the provider firewall allows only the ports required by your workloads. The bootstrap enables Nginx and Fail2Ban but does not enable a firewall.

## Quick Start

```fish
git clone https://github.com/YOUR_GITHUB_ACCOUNT/node2-ops-kit.git
cd node2-ops-kit
cp .env.example .env
chmod 600 .env
./scripts/check-local.fish
```

Set `NODE2_HOST` in `.env`, or pass a host to a script. The default is `node2`. Keep an SSH identity loaded in OpenSSH or configure it in `~/.ssh/config`. Before running a deployment command, verify the server host-key fingerprint through an independent channel and add the verified key to `~/.ssh/known_hosts`; scripts reject unknown host keys.

## Fresh Server Setup

Read [Fresh Installation](docs/FRESH_INSTALL.md) before changing a server. Bootstrap, the explicit Quadlet profile, and host Nginx/TLS are separate confirmed stages:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/bootstrap-node2.fish root@new-server
./scripts/deploy-stack.fish root@new-server node2-full
```

After deployment, create an SSH tunnel and open `https://localhost:9443`:

```fish
ssh -N -L 9443:127.0.0.1:9443 root@new-server
```

The Portainer service runs under the `doom` user and is started by its user systemd manager after reboot. The application UI is not exposed on a public interface.

To deploy one reviewed service, add `deploy/quadlet/node2/SERVICE_NAME.container` and run `./scripts/deploy-node2.fish root@new-server SERVICE_NAME`. The command installs the selected node2 unit and shared network/volume files, starts its generated service, and verifies that systemd reports it active.

After DNS points to the server, configure Nginx, request the Let's Encrypt certificate, and enable the Fail2Ban Nginx jails:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/configure-web.fish root@new-server
```

The web configuration requires real `NODE2_DOMAIN` and `LETSENCRYPT_EMAIL` values in `.env`. It first serves the ACME challenge over HTTP, requests the certificate with Certbot, then installs the HTTPS configuration. Nginx writes `$http_range` and `$sent_http_content_range` to a JSON access log for download analysis.

Portainer initializes its administrator during first access. Complete that setup through the SSH tunnel and store the credentials in a password manager.

## Backup and Recovery

```fish
./scripts/backup-node2.fish node2
./scripts/validate-node2.fish node2
```

Restore and activation write to the host, so set the confirmation variable for each command:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/restore-node2.fish node2 backups/node2-YYYYmmddTHHMMSSZ
./scripts/validate-node2.fish node2
./scripts/activate-node2.fish node2
```

Review [Operations](docs/OPERATIONS.md), [Architecture](docs/ARCHITECTURE.md), and [Security](docs/SECURITY.md) before using restore on a production host.

## Configuration

Copy `.env.example` to `.env`, keep it mode `600`, and only add trusted shell assignments. The scripts source this file as Bash syntax. Values exported by the caller take precedence over `.env`.

| Variable | Purpose | Default |
|---|---|---|
| `NODE2_HOST` | SSH host or `user@host` target | `node2` |
| `NODE2_USER` | SSH user when the target has no username | `root` |
| `NODE2_SSH_KEY` | Optional SSH private-key path | OpenSSH default |
| `NODE2_DOMAIN` | DNS name for the Nginx site and certificate | required for `configure-web` |
| `LETSENCRYPT_EMAIL` | ACME account email | required for `configure-web` |
| `NODE2_WEB_ROOT` | Host ACME challenge root | `/var/www/node2` |
| `NODE2_XUI_PANEL_PATH` | Random 3X-UI URL path, also set in panel on first run | required for `configure-web` |
| `NODE2_DNS_PANEL_PATH` | Random DNS panel URL path | required for `configure-web` |
| `NODE2_DNS_ALLOWED_CIDR` | Trusted source network for DNS panel | defaults to localhost only |
| `NODE2_PANEL_USER` | Nginx Basic Auth user for 3X-UI | required for `configure-web` |
| `NODE2_PANEL_PASSWORD` | Nginx Basic Auth password, 20+ characters | required for `configure-web` |
| `BACKUP_ROOT` | Local destination for timestamped backups | `backups` |
| `DEPLOY_CONFIRM` | Required `YES` for bootstrap, deployment, restore, and activation | `NO` |

Never commit `.env`, credentials, keys, certificates, databases, logs, or backup archives. Backups may contain sensitive host configuration; encrypt them and restrict access.

## Repository Layout

```text
scripts/                  Operator-side Bash and fish commands
scripts/lib/common.sh     Shared SSH, environment, and confirmation helpers
deploy/quadlet/node2/     Rootless Quadlet manifest set for node2
deploy/quadlet/node1/     Node1-only manifests, excluded from node2 profile
deploy/config/            Alloy, Loki, Nextcloud, DNS collector config/code
deploy/host/nginx/        Host reverse-proxy template, logs, patches
deploy/host/fail2ban/     Host Fail2Ban filters and overlays
deploy/profiles/          Explicit deployment service lists
deploy/systemd/user/      Rootless user metrics timers/services
docs/FRESH_INSTALL.md     Clean-host setup and first-run service initialization
docs/QUADLET.md           Quadlet INI units, generated services, and extension rules
docs/DEPLOYMENT_STAGES.md Complete preparation and deployment lifecycle
docs/ARCHITECTURE.md      Host, user, container, and network boundaries
docs/OPERATIONS.md        Backup, restore, validation, and recovery procedures
docs/SECURITY.md          Secrets, privileges, exposure, and threat limits
.env.example              Public operator configuration template
.github/workflows/        CI checks and public project packaging
```

## Local Checks

```fish
bash -n scripts/*.sh scripts/lib/*.sh
fish -n scripts/*.fish
git diff --check
```

GitHub Actions also validates Nginx and Fail2Ban configurations on a disposable runner, parses Quadlet manifests without starting them, and smoke-tests Alloy-to-Loki ingestion in temporary containers. It scans for common accidental secret patterns and creates a configuration-only artifact without `.env` files or local backups. The workflow has no deployment job, SSH credentials, or production secrets; see [CI checks](docs/CI.md).

## License

MIT. See [LICENSE](LICENSE).
