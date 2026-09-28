# Node2 Ops Kit

**A small, understandable toolkit for preparing and maintaining a Linux server.** It backs up host configuration, bootstraps a clean Debian or Ubuntu machine, restores reviewed configuration, and validates services before activation.

**Suggested GitHub repository:** `node2-ops-kit`

**GitHub description:** `Simple, safety-minded automation for bootstrapping, backing up, restoring, and validating a Debian/Ubuntu server running Nginx, Fail2Ban, Podman, Alloy, and Loki.`

The project follows KISS: a few readable Bash and fish scripts, plain configuration files, SSH for remote operations, and explicit boundaries between read-only checks and changes to a server. It does not hide infrastructure behind a framework.

## What It Does

- Checks local tools and basic environment setup before a run.
- Connects to a server over SSH without asking for an interactive password.
- Captures a timestamped backup of host configuration, service status, container metadata, and selected application configuration.
- Writes SHA-256 checksums for each backup artifact and verifies them before restore.
- Installs baseline packages and creates the expected service account and directories on a clean Debian or Ubuntu host.
- Restores reviewed Nginx, Fail2Ban, systemd, Podman, and observability configuration.
- Validates Nginx, Fail2Ban, Podman Compose, Alloy, and service state without restarting services.
- Activates reviewed configuration only after an explicit confirmation flag.
- Supports Nginx download logging with the requested and returned byte ranges, making segmented downloads easier to investigate in Loki.
- Runs shell checks and packages a public project bundle in GitHub Actions. Production deployment is intentionally not automated.

## What It Does Not Do

- It does not back up application databases, user uploads, or container volume data. Those can be large and need a separate retention and encryption policy.
- It does not configure SSH keys, DNS, TLS certificates, or firewall policy on a new server.
- It does not put production credentials in the repository or pass them to GitHub Actions.
- It does not make a restored server live automatically. Restore and activation are separate steps.

## Requirements

On the operator machine:

- Git, OpenSSH client, Bash, tar, and `sha256sum`.
- fish for the documented command wrappers.
- An SSH key that can connect to the target without an interactive password prompt.

On the target:

- Debian or Ubuntu with systemd and root or sudo access.
- A network connection to the distribution package repositories.
- For observability validation and activation: Podman Compose and the existing Alloy/Loki configuration.

## Quick Start

Clone the project, configure the private local environment file, check prerequisites, then take a backup:

```fish
git clone https://github.com/ORG/node2-ops-kit.git
cd node2-ops-kit
cp .env.example .env
chmod 600 .env
./scripts/check-local.fish
./scripts/backup-node2.fish node2
```

The default target is `node2`. Set `NODE2_HOST` in `.env`, pass a host to a script, or define an SSH alias in `~/.ssh/config`. The SSH identity should already be available to OpenSSH; `NODE2_SSH_KEY` can select a specific private key.

## Setting Up a Clean Server

Bootstrap installs baseline Debian/Ubuntu packages, creates the `doom` account if it does not exist, prepares observability directories, and enables Nginx and Fail2Ban. It deliberately leaves SSH access, DNS, certificates, and firewall policy alone.

```fish
./scripts/bootstrap-node2.fish root@new-server
```

Bootstrap changes the target and requires root SSH access. Review the script before running it on a production host.

## Restore and Activate

Restore writes archived files directly to their original paths. It can replace files on the target, so make a fresh backup first and inspect the archive before proceeding.

```fish
./scripts/backup-node2.fish new-server
set -lx DEPLOY_CONFIRM YES
./scripts/restore-node2.fish new-server backups/node2-YYYYmmddTHHMMSSZ
./scripts/validate-node2.fish new-server
```

Validation is read-only. Only after reviewing its results, activate services explicitly:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/activate-node2.fish new-server
```

Activation tests Nginx configuration, checks Fail2Ban, reloads Nginx, restarts Fail2Ban, and runs `podman-compose up -d` for the observability stack when its compose file exists. It does not apply firewall rules.

## Configuration and Secrets

Copy `.env.example` to `.env` and keep the file private with mode `600`. The scripts source `.env` as shell syntax, so only put trusted values in it. Do not commit `.env`, private keys, certificates, tokens, databases, logs, or backup archives.

| Variable | Purpose | Default |
|---|---|---|
| `NODE2_HOST` | SSH host or `user@host` target | `node2` |
| `NODE2_USER` | SSH username used when host has no username | `root` |
| `NODE2_SSH_KEY` | Optional private-key path | OpenSSH default |
| `BACKUP_ROOT` | Local destination for timestamped backups | `backups` |
| `DEPLOY_CONFIRM` | Required `YES` for restore and activate | `NO` |
| `ACTIVATE` | Reserved for future automation | `NO` |

Application secrets belong in a secret manager or protected files on the server, not in this repository. Backups may contain sensitive host configuration; store them encrypted and limit access.

## Project Layout

```text
scripts/
  lib/common.sh             Shared safety helpers
  check-local.fish          Check operator-machine prerequisites
  bootstrap-node2.fish      Prepare a clean Debian/Ubuntu host
  backup-node2.fish         Create a timestamped backup
  restore-node2.fish        Verify and restore a selected backup
  validate-node2.fish       Run read-only service/config checks
  activate-node2.fish       Explicitly reload/restart services
  *.sh                      Bash implementations
docs/
  ARCHITECTURE.md           Services and data flow
  OPERATIONS.md             Backup, restore, recovery, diagnosis
  SECURITY.md               Secret handling and threat boundaries
.env.example                Public configuration template
.github/workflows/           CI validation and public bundle packaging
```

## Common Commands

Run from the repository root:

```fish
./scripts/check-local.fish
./scripts/backup-node2.fish node2
./scripts/validate-node2.fish node2
bash -n scripts/*.sh scripts/lib/*.sh
git diff --check
```

To confirm an archive locally:

```fish
cd backups/node2-YYYYmmddTHHMMSSZ
sha256sum -c checksums.sha256
```

See [Operations](docs/OPERATIONS.md), [Architecture](docs/ARCHITECTURE.md), and [Security](docs/SECURITY.md) for full procedures and limits.

## GitHub Actions

The workflow checks shell syntax and obvious secret patterns, then packages the public project files. It does not include local backups or `.env` files. Scheduled/manual CI never deploys to a production host.

## Contributing

Keep changes small and readable. Document new environment variables in `.env.example`, preserve the separation between read-only and write operations, and include validation and rollback notes in pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
