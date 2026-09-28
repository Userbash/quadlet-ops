# Architecture

## Design

The toolkit keeps the host baseline small and uses one unprivileged Linux account for rootless containers. Bash scripts connect over SSH; fish wrappers provide a consistent operator interface. Quadlet turns the Portainer container declaration into a user systemd service.

```text
operator workstation
  | SSH (key authentication)
  +-- bootstrap --> Debian/Ubuntu host
  |                  +-- Nginx and Fail2Ban (system services)
  |                  +-- doom (unprivileged service account)
  |                       +-- rootless Podman API socket
  |                       +-- Portainer Quadlet -> portainer.service
  |                  +-- Nginx HTTP/HTTPS -> web root and JSON download log
  |                  +-- Certbot -> /etc/letsencrypt certificate renewal
  |                  +-- Fail2Ban -> Nginx jail actions
  +-- backup / validate / restore / activate
```

## Ownership and Privileges

- The operator connects as root because the current scripts install packages, inspect host configuration, and restore files under `/etc`. Use a dedicated SSH key and restrict its source network at the provider firewall. A future least-privilege sudo policy must be designed before replacing root access.
- `doom` owns container images, containers, and Portainer's persistent data. It is not added to `sudo`, `wheel`, or a privileged container group.
- Bootstrap creates the rootless named volume `portainer_data`; the Portainer unit mounts it at `/data` so the UI database survives container replacement.
- Subordinate UID and GID ranges are allocated only when the account lacks a usable mapping. The bootstrap avoids ranges already present in `/etc/subuid` and `/etc/subgid`.
- `loginctl enable-linger doom` keeps the user's systemd manager alive at boot and after logout. The bootstrap starts and checks that manager, then enables the user Podman socket.
- Portainer receives the `doom` user's Podman socket. This grants control over that user's containers and data. It is not a rootful Podman socket, but Portainer rootless support is currently not vendor-supported.

## Services and Network

- Nginx and Fail2Ban run as host systemd services.
- Workload containers run rootless as `doom`; their Quadlet units are stored in `~/.config/containers/systemd`.
- The provided Portainer unit binds HTTPS to `127.0.0.1:9443`. It does not publish Portainer to a public interface and does not create firewall rules.
- Nginx serves `NODE2_WEB_ROOT`, logs download ranges as JSON, and uses Certbot-managed certificates after DNS and HTTP reachability are ready.
- Fail2Ban reads host Nginx logs and the configured jail file. It does not replace provider-level firewall rules.
- Use an SSH local-forward for initial access. A public deployment requires a separately reviewed Nginx TLS proxy, DNS, and provider firewall rules.
- The project does not ship application-specific Compose files. Each application should have a reviewed, version-controlled deployment definition, persistent-data plan, health check, and secret handling policy.

## First-Install Flow

1. Provision a clean Debian or Ubuntu system with systemd and SSH key access.
2. Configure the local `.env` and verify the SSH connection.
3. Run the confirmed bootstrap. It installs baseline packages, prepares `doom` and rootless Podman, and starts Nginx and Fail2Ban.
4. Run the confirmed deployment. It installs the Portainer Quadlet and starts `portainer.service` as `doom`.
5. Reach Portainer through SSH forwarding, finish its initial admin setup, and deploy reviewed workload definitions.
6. Configure DNS, TLS, firewall rules, and application backups as separate reviewed operations.

## State and Recovery

Host and selected service configuration are captured in timestamped local archives with SHA-256 manifests. Restore verifies those manifests, but then writes archive paths directly to the target. Validation does not restart services; activation is separate and requires confirmation. Application databases, uploads, and Podman storage are not included.

## Portainer Compatibility

Portainer communicates with Podman using its Docker-compatible API. Current Portainer documentation identifies rootful Podman 5 on CentOS 9 as the supported baseline and says rootless use may work but is not officially supported. This project intentionally keeps application containers rootless on Debian/Ubuntu; the Portainer integration is optional and best-effort. See [Portainer Podman requirements](https://docs.portainer.io/admin/environments/add/podman) and [Podman Quadlet documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).
