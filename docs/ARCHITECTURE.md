# Architecture

## Design

The toolkit keeps host edge services separate and uses one unprivileged Linux account for rootless containers. Bash scripts connect over SSH; fish wrappers provide a consistent operator interface. Quadlet turns each profile declaration into a `doom` user systemd service. See [Quadlet Services](QUADLET.md) for the unit structure.

```text
operator workstation
  | SSH (key authentication)
  +-- bootstrap --> Debian/Ubuntu host
  |                  +-- Nginx and Fail2Ban (system services)
  |                  +-- doom (unprivileged service account)
  |                       +-- rootless Podman API socket
  |                       +-- Node2 Quadlet profile -> app and observability services
  |                  +-- Nginx HTTP/HTTPS -> loopback container backends
  |                  +-- Certbot -> /etc/letsencrypt certificate renewal
  |                  +-- Fail2Ban -> Nginx jail actions
  +-- backup / validate / restore / activate
```

## Ownership and Privileges

- The operator connects as root because the current scripts install packages, inspect host configuration, and restore files under `/etc`. Use a dedicated SSH key and restrict its source network at the provider firewall. A future least-privilege sudo policy must be designed before replacing root access.
- `doom` owns container images, containers, and bind-mounted service configuration/data. It is not added to `sudo` or `wheel`; the journald group is used only for Alloy log collection.
- Bootstrap creates the rootless named volume `portainer_data`; the Portainer unit mounts it at `/data` so the UI database survives container replacement.
- Subordinate UID and GID ranges are allocated only when the account lacks a usable mapping. The bootstrap avoids ranges already present in `/etc/subuid` and `/etc/subgid`.
- `loginctl enable-linger doom` keeps the user's systemd manager alive at boot and after logout. The bootstrap starts and checks that manager, then enables the user Podman socket.
- Portainer receives the `doom` user's Podman socket. This grants control over that user's containers and data. It is not a rootful Podman socket, but Portainer rootless support is currently not vendor-supported.

## Services and Network

- Nginx and Fail2Ban run as host systemd services.
- Workload containers run rootless as `doom`; their Quadlet units are stored in `~/.config/containers/systemd`.
- The provided Portainer unit binds HTTPS to `127.0.0.1:9443`. It does not publish Portainer to a public interface and does not create firewall rules.
- Nginx terminates TLS and proxies to loopback-only app ports. Certbot certificates are issued only after the root and subdomain DNS records resolve to the host.
- Fail2Ban reads host Nginx logs and the configured jail file. It does not replace provider-level firewall rules.
- DNS, provider firewall rules, panel base paths, and application first-run setup remain environment-specific.
- The profile ships service configurations, not user databases, uploads, zones, credentials, certificates, or container storage.

## First-Install Flow

1. Provision a clean Debian or Ubuntu system with systemd and SSH key access.
2. Configure the local `.env` and verify the SSH connection.
3. Run the confirmed bootstrap. It installs baseline packages, prepares `doom` and rootless Podman, and starts Nginx and Fail2Ban.
4. Run the confirmed `node2-full` deployment. It installs Quadlet units and builds the pinned 3X-UI image as `doom`.
5. Verify the rootless services, then configure web hostnames, Nginx/TLS, Fail2Ban, and metric collection after DNS is active.
6. Initialize the apps and choose a separate application-data backup policy.

## State and Recovery

Host and selected service configuration are captured in timestamped local archives with SHA-256 manifests. Backups omit secrets, auth hashes, private keys, databases, uploads, DNS zones, logs, caches, and Podman storage. Validation does not restart services; activation is separate and requires confirmation.

## Portainer Compatibility

Portainer communicates with Podman using its Docker-compatible API. Current Portainer documentation identifies rootful Podman 5 on CentOS 9 as the supported baseline and says rootless use may work but is not officially supported. This project intentionally keeps application containers rootless on Debian/Ubuntu; the Portainer integration is optional and best-effort. See [Portainer Podman requirements](https://docs.portainer.io/admin/environments/add/podman) and [Podman Quadlet documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).
