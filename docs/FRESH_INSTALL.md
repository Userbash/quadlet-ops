# Fresh Server Installation

This runbook takes a clean Debian or Ubuntu server to a prepared host with rootless Podman and an optional Portainer instance. It does not silently configure networking or deploy application-specific services.

## 1. Provision the Host

Create a Debian or Ubuntu server with systemd, a public or private address reachable from the operator workstation, and enough storage for the operating system plus the container workloads you intend to add. Workload storage requirements depend on the chosen applications; this repository does not prescribe a universal disk size.

Before connecting, install an operator SSH public key through the provider console. Keep console access available until remote access is verified. At the provider firewall, allow SSH only from trusted source addresses. Do not open Portainer's 9443 port; the provided service listens on loopback.

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

1. Installs Nginx, Fail2Ban, Podman, Podman Compose, `uidmap`, rootless networking/storage helpers, and supporting tools from the OS package repositories.
2. Creates `doom` if it does not exist. An existing account is not recreated or moved; it must already use `/home/doom` as its home directory.
3. Adds a non-overlapping 65,536-ID subordinate UID and GID range if the account does not already have a usable range.
4. Creates the container Quadlet, observability, backup, and Portainer data directories owned by `doom`.
5. Enables lingering and starts `user@UID.service`, using the actual UID assigned by the operating system.
6. Enables the rootless Podman socket and runs `podman info` as `doom` to verify the runtime.
7. Enables and starts Nginx and Fail2Ban.
8. Generates a random Portainer administrator password, stores its bcrypt hash for the container, and saves the plaintext credential file as root-only data under `/home/doom/portainer/secrets`.
9. Creates and verifies the rootless Podman named volume `portainer_data`.
10. Enables APT unattended upgrades limited to the detected Debian or Ubuntu security origin. It does not update ordinary feature packages or container images.

Review the result before moving on:

```fish
ssh root@203.0.113.10 'id doom; grep ^doom: /etc/subuid /etc/subgid; loginctl show-user doom -p Linger'
ssh root@203.0.113.10 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman info --format json'
ssh root@203.0.113.10 'systemctl is-active nginx fail2ban'
```

## 4. Deploy Portainer

Portainer deployment is a separate confirmed action. It installs the repository's Quadlet file, reloads `doom`'s user systemd manager, starts the service, and checks that it is active:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@203.0.113.10
```

The unit stores data in `/home/doom/portainer/data`, mounts only `doom`'s Podman socket, and binds HTTPS to `127.0.0.1:9443`. Quadlet and the lingering user systemd manager provide restart after reboot.

Create a local SSH tunnel:

```fish
ssh -N -L 9443:127.0.0.1:9443 root@203.0.113.10
```

Keep the tunnel running and open `https://localhost:9443`. The certificate is self-signed by default. Complete Portainer's initial administrator setup promptly and store the credentials in a password manager.

Portainer uses Podman's Docker-compatible API, not a native Podman integration. Its current documentation lists rootful Podman 5 on CentOS 9 as the supported baseline and says rootless use may work but is not officially supported. Node2 Ops Kit deliberately uses rootless Podman on Debian/Ubuntu, so treat Portainer as optional and best-effort. Review the [Portainer Podman requirements](https://docs.portainer.io/admin/environments/add/podman) before relying on Portainer features.

The generated administrator credential is available only on the target:

```fish
ssh root@203.0.113.10 'cat /home/doom/portainer/secrets/admin-credentials.txt'
```

Run this only through a trusted terminal. The file is mode `0600`; do not paste it into GitHub, chat, logs, or shell history. Rotate the password after first login.

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

## 6. Add Application Workloads

The repository intentionally does not deploy guessed application stacks. Before a workload goes live, add a reviewed deployment definition and decide:

- Exact image and update policy.
- Required ports and whether they bind to loopback or a private container network.
- Persistent data paths, ownership, backup, restore, and retention.
- Health checks, resource limits, startup ordering, and restart behavior.
- Secret sources and file permissions.
- How the service is validated and rolled back.

Prefer Quadlet for systemd-managed containers. Put reviewed rootless definitions in the repository's `deploy/SERVICE_NAME.container` and use the deployment command to install it under `/home/doom/.config/containers/systemd`, reload the user manager, start it, and check the generated service state:

```fish
./scripts/deploy-node2.fish root@203.0.113.10 SERVICE_NAME
```

A `.container` unit can declare its image, mounts, network, and published ports; `WantedBy=default.target` lets the Quadlet generator attach it to the user default target. Create any required server-side secret files and data directories with correct ownership before deploying. The deploy command verifies that systemd reports the generated service active; only Portainer has an additional HTTPS API readiness check. The repository does not yet provide an application catalog or generate workload-specific configuration.

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

Backups contain sensitive configuration and should be encrypted before off-host storage. The current backup is not an application-data backup: databases, uploads, and container storage are excluded.

See [Operations](OPERATIONS.md) for restore, activation, diagnostics, and rollback. Restore and activation are separate confirmed operations.
