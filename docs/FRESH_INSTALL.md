# Fresh Server Installation

This runbook prepares a clean Debian or Ubuntu server for the node2 service profile. Application containers run through rootless Quadlet under `doom`; Nginx and Fail2Ban remain host services. User databases, uploads, DNS zones, and TLS private keys are not copied into this project.

## 1. Provision the Host

Create a Debian or Ubuntu server with systemd, a public or private address reachable from the operator workstation, and enough storage for the operating system plus the container workloads you intend to add. Workload storage requirements depend on the chosen applications; this repository does not prescribe a universal disk size.

Before connecting, install an operator SSH public key through the provider console. Keep console access available until remote access is verified. Verify the server host-key fingerprint through the provider console or another independent channel, then add that verified key to the operator's `~/.ssh/known_hosts`. The scripts reject unknown host keys; do not trust an unverified `ssh-keyscan` result. At the provider firewall, allow SSH only from trusted source addresses. Do not open Portainer's 9443 port; the provided service listens on loopback.

The current scripts require key-based root SSH access. The `doom` account created by bootstrap is a separate service account and is not the operator account.

## 2. Prepare the Operator Workstation

Install Git, fish, Bash, OpenSSH client, tar, and `sha256sum`. Clone the project, create the private environment file, and check the local tools:

```fish
git clone https://github.com/YOUR_GITHUB_ACCOUNT/node2-ops-kit.git
cd node2-ops-kit
cp .env.example .env
chmod 600 .env
```

Edit `.env` if needed. For example:

```text
NODE2_HOST=203.0.113.10
NODE2_USER=root
# NODE2_SSH_KEY=/home/operator/.ssh/node2
BACKUP_ROOT=backups
DEPLOY_CONFIRM=NO
```

The example IP above is reserved for documentation. Replace it with the actual server address. Ensure the SSH key is loaded or configured in `~/.ssh/config`, then run:

```fish
./scripts/check-local.fish
ssh root@203.0.113.10 true
```

## 3. Bootstrap the Host

Bootstrap installs baseline packages and configures the `doom` rootless-container account. It also enables Nginx and Fail2Ban. It does not change SSH, DNS, TLS, or firewall settings.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/bootstrap-node2.fish root@203.0.113.10
```

The script performs these checks and changes:

1. Installs Nginx, Fail2Ban, Podman, `uidmap`, rootless networking/storage helpers, and supporting tools from the OS package repositories.
2. Creates `doom` if it does not exist. An existing account is not recreated or moved; it must already use `/home/doom` as its home directory.
3. Adds a non-overlapping 65,536-ID subordinate UID and GID range if the account does not already have a usable range.
4. Creates the container Quadlet, observability, backup, and Portainer data directories owned by `doom`.
5. Enables lingering and starts `user@UID.service`, using the actual UID assigned by the operating system.
6. Enables the rootless Podman socket and runs `podman info` as `doom` to verify the runtime.
7. Enables and starts Nginx and Fail2Ban.
8. Creates and verifies the rootless Podman named volume `portainer_data`.
9. Enables APT unattended upgrades limited to the detected Debian or Ubuntu security origin. It does not update ordinary feature packages or container images.

Review the result before moving on:

```fish
ssh root@203.0.113.10 'id doom; grep ^doom: /etc/subuid /etc/subgid; loginctl show-user doom -p Linger'
ssh root@203.0.113.10 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman info --format json'
ssh root@203.0.113.10 'systemctl is-active nginx fail2ban'
```

## 4. Deploy the Quadlet Profile

Set a real domain, panel paths, DNS allowlist, and Basic Auth password in `.env`. Then deploy the explicit node2 profile:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-stack.fish root@203.0.113.10 node2-full
```

The script installs only `deploy/quadlet/node2` definitions, copies service configuration, creates empty data directories and new Nextcloud credentials, and builds 3X-UI from the pinned v3.9.0 source commit as `doom`. It does not copy node2 databases, uploads, DNS zones, tokens, certificates, or `.env` files. The optional Technitium stats collector starts only when a new `NODE2_TECHNITIUM_API_TOKEN` is supplied.

Portainer binds HTTPS to `127.0.0.1:9443` and mounts the rootless Podman socket. Create a local SSH tunnel:

```fish
ssh -N -L 9443:127.0.0.1:9443 root@203.0.113.10
```

Keep the tunnel running and open `https://localhost:9443`. The certificate is self-signed by default. Complete Portainer's initial administrator setup promptly and store the credentials in a password manager.

Portainer uses Podman's Docker-compatible API, not a native Podman integration. Its current documentation lists rootful Podman 5 on CentOS 9 as the supported baseline and says rootless use may work but is not officially supported. Node2 Ops Kit deliberately uses rootless Podman on Debian/Ubuntu, so treat Portainer as optional and best-effort. Review the [Portainer Podman requirements](https://docs.portainer.io/admin/environments/add/podman) before relying on Portainer features.

## 5. Configure Host Networking and Web Services

Apply network rules in the cloud provider's firewall or another reviewed network control. Typical inbound rules are:

- TCP 22 from trusted operator addresses.
- TCP 80 and 443 only if a public HTTP service or TLS reverse proxy is configured.
- No public rule for TCP 9443. Use the SSH tunnel for Portainer.
- Do not expose the Podman socket over TCP.

DNS records and provider firewall rules remain site-specific. After DNS resolves to the server and TCP 80 is reachable for ACME validation, set `NODE2_DOMAIN` and `LETSENCRYPT_EMAIL` in `.env` and run:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/configure-web.fish root@203.0.113.10
```

The command installs a temporary HTTP site, obtains a certificate through Certbot's webroot challenge, installs the final HTTPS Nginx configuration, and enables a Fail2Ban jail for Nginx authentication and bot scans. It does not open ports in a provider firewall.

## 6. First-Run Application Setup

The service profile starts empty application storage. Before exposing services, initialize Nextcloud, 3X-UI, Open WebUI, and Technitium, and verify their intended admin accounts and host names. Nextcloud's generated administrator credential is stored mode `0600` at `/home/doom/nextcloud/admin-credentials.txt`; the private `.env` remains at `/home/doom/nextcloud/.env`. Set the 3X-UI admin base path to the same value as `NODE2_XUI_PANEL_PATH`.

The rootless data paths are created under `/home/doom`; bind-mounted app state stays outside the repository. Do not copy DNS zones or application data into the configuration backup.

To add a later workload, add a reviewed Quadlet definition and decide:

- Exact image and update policy.
- Required ports and whether they bind to loopback or a private container network.
- Persistent data paths, ownership, backup, restore, and retention.
- Health checks, resource limits, startup ordering, and restart behavior.
- Secret sources and file permissions.
- How the service is validated and rolled back.

Put reviewed node2 definitions in `deploy/quadlet/node2/SERVICE_NAME.container` and use the deployment command to install it under `/home/doom/.config/containers/systemd`:

```fish
./scripts/deploy-node2.fish root@203.0.113.10 SERVICE_NAME
```

A `.container` unit can declare its image, mounts, network, and published ports; `WantedBy=default.target` lets the Quadlet generator attach it to the user default target. The node2 profile also has bounded readiness checks for Portainer, Qdrant, Loki, and VictoriaMetrics. Other applications require their first-run initialization and manual acceptance checks.

Do not manage the same container from both Portainer and a systemd/Quadlet unit. Pick one controller per workload to avoid conflicting create, update, and removal operations.

## 7. Validate, Back Up, and Operate

Run read-only validation:

```fish
./scripts/validate-node2.fish root@203.0.113.10
```

Create and verify a backup:

```fish
./scripts/backup-node2.fish root@203.0.113.10
cd backups/node2-YYYYmmddTHHMMSSZ
sha256sum -c checksums.sha256
cd ../..
```

Backups contain an allowlist of configuration and should be encrypted before off-host storage. Credentials, auth hashes, private keys, databases, uploads, DNS zones, logs, caches, and container storage are excluded.

See [Operations](OPERATIONS.md) for restore, activation, diagnostics, and rollback. Restore and activation are separate confirmed operations.
