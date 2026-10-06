# Deployment Stages

This document defines the deployment lifecycle for a clean Debian or Ubuntu host. Application containers run rootless under `doom`. Node2 Quadlets live in `deploy/quadlet/node2`, node1-only units live in `deploy/quadlet/node1`, and the explicit profile is `deploy/profiles/node2-full.units`.

## Stage 0: Scope and Preconditions

Before touching a server, record the target hostname, domain, operator SSH key, provider firewall rules, required applications, persistent data paths, and rollback plan. The repository contains reviewed Quadlet definitions for the Node2 workloads; each target installation still requires a host-specific review of paths, secrets, and ports.

Required preconditions:

- Debian or Ubuntu with systemd and network access to package repositories and container registries.
- Root SSH key access for the current bootstrap implementation.
- Provider firewall rules that allow SSH and, when needed, HTTP/HTTPS. Portainer remains loopback-only.
- Real `NODE2_DOMAIN` and `LETSENCRYPT_EMAIL` values before the web stage.

Before the first deployment, verify the SSH host-key fingerprint through the provider console or another independent channel and add it to the operator's `known_hosts`. The scripts reject unknown host keys. Acceptance: `ssh root@HOST true` succeeds without an interactive password prompt and the returned host key matches the independently verified fingerprint.

## Stage 1: Operator Workspace

```fish
cp .env.example .env
chmod 600 .env
./scripts/check-local.fish
```

Set the required `NODE2_*`, domain, panel path, and auth variables in `.env`; keep it mode `600` and out of Git. Never put private keys, certificates, or service data there.

Acceptance: local Bash and fish prerequisites pass; `.env` is mode `600`.

## Stage 2: Host Bootstrap

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/bootstrap-node2.fish root@HOST
```

Bootstrap installs the host packages needed by the platform, creates or verifies `/home/doom`, allocates subordinate UID/GID ranges, prepares directories, enables user lingering, starts the `doom` user manager and rootless `podman.socket`, creates `portainer_data`, and starts host Nginx and Fail2Ban.

Acceptance:

```fish
ssh root@HOST 'id doom; loginctl show-user doom -p Linger; systemctl is-active nginx fail2ban'
ssh root@HOST 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman info'
```

## Stage 3: Quadlet Runtime

Every container is represented by a Quadlet INI or `.kube` file under `deploy/quadlet/node2/`. The unit is copied to `/home/doom/.config/containers/systemd/` and generated into a user systemd service. No Compose service or rootful Podman service is used by the deployment path.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-stack.fish root@HOST
```

`deploy-stack` uploads only the explicit node2 profile, copies settings without application data, builds pinned 3X-UI source as `doom`, and starts services in dependency order. It does not scan arbitrary deploy files. Host Nginx/TLS, Fail2Ban, and HTTP metric validation remain a separate stage that needs working DNS.

Acceptance: `./scripts/check-stack.fish root@HOST` reports every Quadlet service active.

## Stage 4: Web and Certificate Configuration

The current web automation configures host Nginx, not an Nginx container. This is intentional: rootless containers cannot safely bind privileged ports 80/443 without an external port-forwarding layer. It installs a temporary HTTP site, obtains the certificate through Certbot webroot validation, then installs the final HTTPS site and Fail2Ban jail.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/configure-web.fish root@HOST
```

Acceptance:

```fish
ssh root@HOST 'nginx -t; certbot certificates; fail2ban-client ping'
```

## Stage 5: Application Units

For each application, add a separate Quadlet INI file. The file must declare image, ports, networks, mounts, secrets, restart policy, and install target. A workload is not considered deployed until its unit is active and its application-specific readiness check passes.

```text
deploy/app-name.container
```

Deploy all reviewed units with `deploy-stack`. Do not manage a Quadlet-owned container from Portainer as well; use one lifecycle controller per workload.

Application data is separate from image and configuration state. Define a volume backup and restore procedure before deploying a database or stateful service.

## Stage 6: Security Updates and Software

The repository installs packages from the distribution repositories. It does not pin arbitrary third-party repositories or silently replace application images. It configures unattended security updates for the host; ordinary package updates and container image updates remain explicit operations.

The bootstrap writes `/etc/apt/apt.conf.d/52-node2-security-only` and enables the standard `apt-daily` timers. The security origin is selected from `/etc/os-release`; unsupported distributions fail before the bootstrap completes.

Recommended controls:

- Enable the distribution's security repository.
- Define an unattended security update policy appropriate for the workload.
- Pin or review container image tags; avoid unreviewed `latest` updates for stateful applications.
- Retain backups and test rollback before changing images or units.

## Stage 7: Verification

```fish
./scripts/validate-node2.fish root@HOST
./scripts/check-stack.fish root@HOST
```

Verify Nginx configuration, Fail2Ban, user systemd services, Podman containers, exposed ports, certificate expiry, and application health endpoints. Keep checks bounded and fail the deployment when a required service is not active.

## Stage 8: Backup and Rollback

```fish
./scripts/backup-node2.fish root@HOST
```

The backup includes an allowlist of host and application configuration. It excludes credentials, auth hashes, certificates/private keys, databases, uploads, DNS zones, logs, caches, images, and named-volume contents. Those require separate protected backup policies.

To roll back a Quadlet unit, restore the previous reviewed INI file, run `deploy-stack` or the selected deployment command, and run `check-stack`. To roll back host configuration, restore a verified archive, run validation, and only then activate services.

## Rootless and Fail2Ban Boundary

Rootless Quadlet is appropriate for application containers and Portainer's user-scoped Podman API. Fail2Ban is different: effective banning requires control of the host firewall. A rootless Fail2Ban container cannot reliably enforce host bans without privileged access, host network access, and firewall capabilities, which conflicts with the `no root` requirement. The current project therefore keeps Fail2Ban as a host service and does not falsely claim a rootless Fail2Ban container provides host protection.

If a future deployment requires every component, including Nginx and Fail2Ban, to be rootless containers, it must use an external rootful edge/firewall layer and non-privileged published ports. That architecture is a separate design and cannot be silently substituted for the current host-service model.
