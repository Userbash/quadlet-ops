# Production Readiness

## Status

This repository contains a reproducible deployment foundation, but it is not yet certified as production-ready. The scripts and manifests have not been exercised end to end on a clean disposable VPS in this review. A successful unit start or local syntax check is not production acceptance.

This assessment covers the deployment repository. It does not authorize or perform changes on the live Node2 host.

## Confirmed Deployment Model

- Workload containers run as rootless Podman Quadlet units owned by `doom`.
- Host Nginx, Fail2Ban, Certbot, and package management remain host services.
- The current bootstrap and host configuration scripts connect over SSH as root by default and require host-level privileges.
- The Node2 profile is explicit; the deployment script starts workloads in profile order.
- Container images are pinned by tag and digest where available. 3X-UI is built from a checked upstream commit.
- The configuration backup excludes application data, credentials, private keys, and container storage. It is not a Nextcloud/database backup.
- Metrics and Fail2Ban actions exist, but they do not replace an operator alert channel, tested disaster recovery, or application-level health checks.

## Release Blockers

### 1. SSH Trust and Operator Privileges

All deployment entry points require a host key that is already trusted in the operator's `known_hosts`; they no longer accept an unseen key automatically. Verify the fingerprint through the provider console or another independent channel before adding it. The documented bootstrap still uses root SSH. Choose and document whether administration uses root SSH or an unprivileged operator with a narrowly scoped, reviewed privilege mechanism. Rootless containers do not by themselves make root SSH safe.

### 2. Deployment Transactions and Recovery

The current service deployer installs a Quadlet file, reloads systemd, restarts the service, and checks `active` state. It does not automatically restore the previous unit when a new container becomes active but fails its application readiness check. The full profile can therefore stop partway through with a mixed set of old and new service versions. Production releases need staged configuration, validation before activation, bounded application checks, per-service rollback, and a release record showing exactly which units changed.

Host web configuration is also applied in multiple steps. A failure during certificate issuance, Nginx replacement, Fail2Ban deployment, or metrics installation can leave a partially applied host configuration. Each step needs a candidate configuration test, a known-good snapshot, atomic activation where possible, health checks, and automatic restoration on failure.

### 3. Data Protection and Recovery Objectives

The existing backup is configuration-only. It excludes Nextcloud uploads and database contents, Portainer state, DNS zones, Qdrant collections, and other named-volume data. Production use requires explicit per-service backup and restore procedures, encryption and off-host retention, consistency handling for databases, periodic restore drills, and agreed recovery point and recovery time objectives (RPO/RTO). Do not describe the current configuration archive as a full server backup.

### 4. Health and Network Acceptance

The stack checker tests systemd `active` state for every listed service but only probes readiness endpoints for Portainer, Qdrant, Loki, and VictoriaMetrics. Production acceptance must include Nextcloud application and database readiness, DNS/DoT/DoH, the intended public Nginx routes, certificate renewal, and a reboot/startup check. Checks should be bounded and must fail closed when an expected service is absent or a probe is inconclusive.

The project intentionally does not configure provider firewall rules. Production rollout must document and verify the exact inbound ports, source restrictions for administrative access, and the fact that internal APIs remain loopback-only.

### 5. Capacity, Isolation, and Monitoring

Only selected collectors have resource limits; workload resource budgets and disk growth controls are not defined consistently. Production needs reviewed CPU, memory, PID, storage, log-retention, and container restart limits, with sufficient headroom for Nextcloud file transfers and VPN traffic. Alerts need an operator delivery path and documented response ownership. Aggregate telemetry can identify pressure but cannot establish that a specific peer is malicious.

### 6. Image and OS Update Policy

Digest pins make a deployment repeatable, not current or vulnerability-free. Establish a supported OS baseline, image inventory, vulnerability review cadence, update window, compatibility checks, and rollback policy. Updates must not silently move mutable tags or run automatically against stateful production workloads. Validate current upstream support and release status before approving a version change.

## Recommended Delivery Sequence

1. Decide the SSH/operator privilege model and pin host identity before allowing a deployment command to mutate a target.
2. Define production topology and exposure: supported OS release, provider firewall, DNS, domains, trusted administrative sources, storage capacity, and required public services.
3. Make per-service deployment transactional: stage and validate candidate files, snapshot current definitions, activate one service at a time, run application-level checks, and restore the previous version if a check fails.
4. Make host Nginx, TLS, Fail2Ban, and metrics installation recoverable with validated candidates and bounded external route checks.
5. Specify and implement encrypted, off-host, service-consistent data backups. Test restoration on an isolated host and record measured RPO/RTO.
6. Set resource and retention budgets. Confirm alerts reach an operator and define who responds to each severity.
7. Add automated validation for shell syntax, Quadlet generation, Nginx/Fail2Ban candidate configuration, profile completeness, secret scanning, and an end-to-end install on a disposable VPS.
8. Perform a production-like rehearsal: clean install, second idempotent run, service restart, host reboot, certificate renewal simulation, backup restore, and deliberate failure/rollback. Record results without including secrets or customer data.
9. Roll out to production only after the rehearsal passes and an operator approves a maintenance window and rollback point.

## Acceptance Criteria

- Host fingerprints are verified before any privileged SSH command; no first-use auto-accept remains.
- The selected operator account has only the privileges required by the documented workflow.
- Re-running bootstrap and deployment is safe and has documented, deterministic effects.
- A failed unit or failed application probe restores the prior known-good service definition and preserves service data.
- Every public hostname and protocol has a bounded end-to-end check; every private listener is verified not to bind publicly.
- Backups cover the agreed service data, are encrypted and retained off-host, and a restore drill meets the declared RPO/RTO.
- Resource limits, log retention, disk alarms, alert routing, and incident ownership are documented and tested.
- A clean-host rehearsal, reboot test, failure injection, rollback, and restoration pass on the supported OS baseline.
- The final release has a reviewed image inventory, generated manifest, test record, and explicit operator approval.

## Out of Scope Until Approved

- Deploying or restarting services on the live Node2 host.
- Changing provider firewall rules, public DNS, or production credentials.
- Changing Nextcloud upload and timeout behavior or VPN/XHTTP limits without workload measurements.
- Deleting rollback artifacts or altering live application data.
