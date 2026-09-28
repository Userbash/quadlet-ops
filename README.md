# Node2 Ops Kit

Node2 Ops Kit is a small set of Bash and fish scripts for preparing and maintaining a Debian or Ubuntu server. It installs a minimal host baseline, prepares a dedicated rootless Podman account, deploys Portainer as a systemd-managed container, and provides separate backup, restore, validation, and activation commands.

**Suggested GitHub repository:** `node2-ops-kit`

**GitHub description:** `Readable automation for bootstrapping a Debian/Ubuntu server, preparing rootless Podman, deploying Portainer, and managing reviewed host configuration over SSH.`

The project is deliberately plain: SSH, shell scripts, systemd, Quadlet, and text configuration. Every command that writes to a server requires `DEPLOY_CONFIRM=YES`. Bootstrap and deployment do not configure SSH, DNS, TLS, or firewall policy.

## Capabilities

- Installs Nginx, Fail2Ban, Podman, Podman Compose, and rootless-container prerequisites on Debian or Ubuntu.
- Creates the unprivileged `doom` service account, provisions subordinate UID/GID ranges, enables a lingering user systemd manager, and starts the rootless Podman socket.
- Deploys Portainer CE using a rootless Podman Quadlet unit, persistent host storage, automatic systemd startup, and a localhost-only HTTPS listener.
- Installs and starts additional reviewed `.container` Quadlet definitions from `deploy/` with the same rootless service account and systemd lifecycle.
- Configures an Nginx download site, JSON range-aware access logs, Certbot/Let's Encrypt certificates, and Fail2Ban jails after DNS is ready.
- Generates Portainer's initial administrator password on the target and stores the credentials outside the repository with restrictive permissions.
- Creates timestamped server backups and SHA-256 manifests; validates the manifest before restore.
- Restores reviewed configuration separately from service activation.
- Runs read-only Nginx, Fail2Ban, Podman Compose, and Alloy validation where their configuration is present.
- Keeps the host-level and container-level responsibilities separate: Nginx and Fail2Ban run on the host; containers run as `doom`.
- Runs shell checks, scans public files for obvious secrets, and packages a public bundle in GitHub Actions.

## Important Limits

- Portainer manages Podman through Podman's Docker-compatible API. Portainer's current documentation says rootless Podman may work but is not officially supported, and its documented supported baseline is rootful Podman 5 on CentOS 9. This project's Debian/Ubuntu plus rootless setup is therefore an optional, best-effort Portainer configuration, not a vendor-supported combination. See [Portainer's Podman requirements](https://docs.portainer.io/admin/environments/add/podman) and [Podman socket instructions](https://docs.portainer.io/admin/environments/add/podman/socket).
- The Portainer listener binds to `127.0.0.1:9443`. Reach it through an SSH tunnel unless you deliberately configure a reviewed TLS reverse proxy.
- The repository contains the platform bootstrap and Portainer unit, not application manifests for Nextcloud, 3x-ui, Open WebUI, or other workloads. Add and review each workload's Quadlet manifest and server-side secret files before deploying it.
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

Set `NODE2_HOST` in `.env`, or pass a host to a script. The default is `node2`. Keep an SSH identity loaded in OpenSSH or configure it in `~/.ssh/config`.

## Fresh Server Setup

Read [Fresh Installation](docs/FRESH_INSTALL.md) before changing a server. In brief, bootstrap and Portainer deployment are separate, confirmed actions:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/bootstrap-node2.fish root@new-server
./scripts/deploy-node2.fish root@new-server
```

After deployment, create an SSH tunnel and open `https://localhost:9443`:

```fish
ssh -N -L 9443:127.0.0.1:9443 root@new-server
```

The Portainer service runs under the `doom` user and is started by its user systemd manager after reboot. The application UI is not exposed on a public interface.

To deploy another reviewed container unit, add `deploy/SERVICE_NAME.container` and run `./scripts/deploy-node2.fish root@new-server SERVICE_NAME`. The command installs it under `doom`'s Quadlet directory, reloads the user manager, starts `SERVICE_NAME.service`, and verifies that systemd reports it active. Prepare required secrets and data paths on the host first.

After DNS points to the server, configure Nginx, request the Let's Encrypt certificate, and enable the Fail2Ban Nginx jails:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/configure-web.fish root@new-server
```

The web configuration requires real `NODE2_DOMAIN` and `LETSENCRYPT_EMAIL` values in `.env`. It first serves the ACME challenge over HTTP, requests the certificate with Certbot, then installs the HTTPS configuration. Nginx writes `$http_range` and `$sent_http_content_range` to a JSON access log for download analysis.

Bootstrap creates a random Portainer admin password on the target. The generated credentials are stored in `/home/doom/portainer/secrets/admin-credentials.txt` with mode `0600` and are never copied into the repository or printed by the scripts. Read them once through a protected root session and rotate them in Portainer after initial setup.

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
| `NODE2_WEB_ROOT` | Host web root for downloads and ACME challenges | `/var/www/node2` |
| `BACKUP_ROOT` | Local destination for timestamped backups | `backups` |
| `DEPLOY_CONFIRM` | Required `YES` for bootstrap, deployment, restore, and activation | `NO` |

Never commit `.env`, credentials, keys, certificates, databases, logs, or backup archives. Backups may contain sensitive host configuration; encrypt them and restrict access.

## Repository Layout

```text
scripts/                  Operator-side Bash and fish commands
scripts/lib/common.sh     Shared SSH, environment, and confirmation helpers
deploy/                   Quadlet definitions installed on the server
deploy/nginx-node2.conf   HTTPS site with range-aware JSON access logging
deploy/fail2ban-nginx.local Nginx authentication and bot jails
docs/FRESH_INSTALL.md     Clean-host setup from prerequisites to Portainer
docs/QUADLET.md           Quadlet INI units, generated services, and extension rules
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

The GitHub Actions workflow runs these syntax checks, scans files for obvious secret patterns, and creates a bundle without `.env` files or local backups. It never deploys to a production host.

## License

MIT. See [LICENSE](LICENSE).
