# Continuous Integration

GitHub Actions runs on pushes to main, pull requests, and manual dispatch. All jobs use disposable hosted runners with a read-only repository token. No SSH keys, production secrets, deployment environment, server connection, or production rollback are configured.

## Checks

- Static checks validate Bash and fish syntax, run ShellCheck, check repository invariants, and scan the checkout for common accidental secret patterns. The scan reports only that a potential match exists and suppresses matching lines.
- Host configuration validation installs Nginx, Fail2Ban, and Podman on a temporary Ubuntu runner. Nginx receives dummy ci.invalid names, temporary self-signed certificates, and a test-only Basic Auth file before nginx -t. Fail2Ban validates a candidate configuration and synthetic documentation-address inputs. The Podman system generator runs in dry-run mode against staged Quadlet manifests; it does not start containers or systemd units.
- Observability smoke test validates both repository Alloy configurations using the pinned Alloy image, then starts temporary Loki and Alloy containers on a private Podman network. It submits one synthetic log line and checks that Loki can query it. The containers, network, and temporary storage are removed when the job exits.
- Configuration bundle packages deployment configuration while excluding environment files, backup directories, keys, certificates, databases, and logs. The artifact is retained by GitHub Actions for 14 days.

## Boundaries

These jobs check syntax, parser acceptance, selected policy invariants, and an isolated telemetry path. They do not test SSH bootstrap on a clean VPS, provider firewall behavior, real DNS or certificate issuance, live application migrations, production traffic, or service rollback against a real host. A successful CI run is not a production deployment or a production-readiness certification.

Testing deployment scripts against a disposable VPS requires a separate short-lived VM with no production data and manually supplied, restricted credentials in a dedicated workflow environment. That workflow is intentionally not part of this repository's default CI.
