# Operations

## Local Preparation

Run commands from the repository root. The operator requires Git, fish, Bash, OpenSSH client, tar, and `sha256sum`.

```fish
cp .env.example .env
chmod 600 .env
./scripts/check-local.fish
ssh root@node2 true
```

Use a key-based SSH connection with no interactive password prompt. Set `NODE2_HOST` in `.env`, use an SSH alias, or pass `root@host` to a script. `DEPLOY_CONFIRM=YES` is required by every command that changes the target.

## Bootstrap a Clean Host

Bootstrap supports Debian and Ubuntu systems using systemd. Before running it, confirm the target is the intended machine and that the provider firewall permits SSH from your address.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/bootstrap-node2.fish root@new-server
```

The script installs Nginx, Fail2Ban, Podman, Podman Compose, and rootless Podman prerequisites. It creates `doom` if missing, allocates a non-overlapping subordinate ID range when needed, creates service directories, enables lingering, starts the user manager and Podman socket, checks `podman info`, and enables Nginx and Fail2Ban.

It does not configure SSH, DNS, certificates, application stacks, or firewall rules. It does not configure a firewall automatically because a mistaken remote firewall change can lock out the operator.

## Deploy Portainer

Bootstrap and Portainer deployment are separate. The deployment installs `deploy/portainer.container` into the `doom` user's Quadlet directory, reloads the user systemd manager, starts `portainer.service`, checks its active state, and waits for the HTTPS API to answer.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@new-server
```

The service binds to `127.0.0.1:9443`, persists Portainer data under `/home/doom/portainer/data`, and starts at boot through the lingering user systemd manager. Open a separate terminal and create a local tunnel:

```fish
ssh -N -L 9443:127.0.0.1:9443 root@new-server
```

Then open `https://localhost:9443` and complete initial Portainer setup. The certificate is self-signed by default. Do not forward port 9443 through the provider firewall. The rootless Podman integration is best-effort; Portainer documents rootful Podman on CentOS 9 with Podman 5 as its supported baseline.

Useful server-side checks:

```fish
ssh root@new-server 'id doom; grep ^doom: /etc/subuid /etc/subgid; loginctl show-user doom -p Linger'
ssh root@new-server 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman ps -a'
ssh root@new-server 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid systemctl --user status portainer.service'
```

## Deploy Application Containers

The repository does not guess which applications belong on a host. Before adding a workload, define its Quadlet or Compose files, image versions, listening addresses, health checks, persistent directories, resource expectations, and recovery procedure. Keep credentials in protected server-side files, not in Git.

For a rootless Quadlet workload, add a reviewed `deploy/SERVICE_NAME.container`, prepare its server-side secrets and data directories, then run:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@new-server SERVICE_NAME
```

The command uploads the unit, reloads `doom`'s user manager, enables and starts `SERVICE_NAME.service`, and checks systemd's active state. Add an application-specific HTTP or database readiness check before treating a workload as healthy. Use `WantedBy=default.target` in a Quadlet `[Install]` section and keep user lingering enabled for startup after reboot. See the [Podman Quadlet manual](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).

For a Compose application, keep the Compose file and a systemd user unit together, validate the Compose configuration first, and run `podman-compose up -d` as `doom`. Avoid starting the same workload from both Portainer and systemd; two controllers can overwrite or recreate each other's state.

## Validate, Back Up, Restore, Activate

Validation is read-only:

```fish
./scripts/validate-node2.fish node2
```

Create a local timestamped backup and verify it before restore:

```fish
./scripts/backup-node2.fish node2
cd backups/node2-YYYYmmddTHHMMSSZ
sha256sum -c checksums.sha256
cd ../..
```

Backups may include private host configuration. Store them encrypted and restrict access. The current backup does not capture live databases, uploads, or container storage.

Restore overwrites files at their original paths. Review the archive and create a fresh backup first:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/restore-node2.fish node2 backups/node2-YYYYmmddTHHMMSSZ
./scripts/validate-node2.fish node2
```

Activation reloads Nginx, restarts Fail2Ban, and starts the existing observability Compose file if present. It does not enable firewall rules. Run it only after reviewing validation results:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/activate-node2.fish node2
```

## Diagnostics

```fish
ssh root@node2 'nginx -t; fail2ban-client status; systemctl status nginx fail2ban'
ssh root@node2 'journalctl -u fail2ban --since "24 hours ago"'
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman ps -a'
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid systemctl --user status portainer.service'
```

## Rollback

If a deployed Quadlet fails, stop its user service, restore the previous reviewed unit, reload the user systemd manager, and start the previous service. For host configuration, restore the matching backup and validate before activation. A rollback is incomplete until service health and external connectivity have been checked.
