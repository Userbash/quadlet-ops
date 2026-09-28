# Quadlet Services

## Scope

Quadlet converts Podman unit files into user systemd services. In this repository, the Quadlet runtime belongs to the unprivileged `doom` account. The server bootstrap creates the user systemd manager, enables lingering, starts the rootless Podman socket, and creates the persistent `portainer_data` volume.

The repository currently contains one container definition:

```text
deploy/portainer.container -> portainer.service
```

Nginx and Fail2Ban are host services, not containers. Alloy, Loki, Nextcloud, 3x-ui, Open WebUI, and other application workloads do not have Quadlet definitions in this repository. The activation script can use an externally supplied `observability-compose.yaml`, but that file is not part of the public project.

## Portainer Container

Source file: [`deploy/portainer.container`](../deploy/portainer.container)

```ini
[Unit]
Description=Portainer CE for the rootless doom Podman environment
Wants=podman.socket
After=podman.socket

[Container]
Image=docker.io/portainer/portainer-ce:lts
ContainerName=portainer
PublishPort=127.0.0.1:9443:9443
Volume=%t/podman/podman.sock:/var/run/docker.sock
Volume=portainer_data:/data
Volume=/home/doom/portainer/secrets/admin-password:/run/secrets/portainer-admin-password:ro
Exec=--admin-password-file /run/secrets/portainer-admin-password

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

### `[Unit]`

`Wants=podman.socket` starts the rootless Podman API socket with the service. `After=podman.socket` orders the generated service after that socket. The socket is owned by the `doom` user systemd manager, not by the host root Podman service.

### `[Container]`

- `Image` selects the Portainer CE long-term-support image. The image is pulled on the target and is not stored in Git.
- `ContainerName` gives the container a stable Podman name.
- `PublishPort=127.0.0.1:9443:9443` keeps Portainer private to the host. Use an SSH tunnel or a separately reviewed reverse proxy for access.
- `%t/podman/podman.sock` resolves to the runtime directory of `doom`, for example `/run/user/1001/podman/podman.sock`. It is mounted at `/var/run/docker.sock` because Portainer speaks Podman's Docker-compatible API.
- `portainer_data:/data` is a rootless named volume created by bootstrap. It holds the Portainer database and configuration.
- The password hash is mounted read-only from `/home/doom/portainer/secrets/admin-password`. Bootstrap generates the hash and keeps the plaintext credentials in a root-only file outside the repository.
- `Exec=--admin-password-file ...` passes the initial admin password hash to the Portainer image. It does not place the password in the Quadlet file or the process command line on the operator workstation.

### `[Service]`

`Restart=always` asks user systemd to restart the container after an exit. `TimeoutStartSec=300` allows time for an image pull and first startup on a new server.

### `[Install]`

`WantedBy=default.target` makes the generated `portainer.service` part of the `doom` user manager's default target. Because bootstrap enables lingering, the service can start after reboot without an interactive login.

## Generated Runtime

The Quadlet file is installed on the target as:

```text
/home/doom/.config/containers/systemd/portainer.container
```

Podman generates the user unit:

```text
portainer.service
```

Inspect it on the server:

```fish
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid systemctl --user cat portainer.service'
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid systemctl --user status portainer.service'
ssh root@node2 'uid=$(id -u doom); runuser -u doom -- env HOME=/home/doom XDG_RUNTIME_DIR=/run/user/$uid podman inspect portainer'
```

The project deployment command uploads the selected unit, reloads the user manager, enables it with `systemctl --user enable --now`, and checks its active state. For Portainer it also waits for `https://127.0.0.1:9443/api/status` to respond.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@node2
```

## Adding Another Container

Add one reviewed file per workload under `deploy/`:

```text
deploy/SERVICE_NAME.container
```

Deploy it with:

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@node2 SERVICE_NAME
```

The file should declare its image, persistent storage, network, published ports, secret mounts, restart policy, and a systemd install target. Before publishing a new unit, document:

- what data survives container replacement;
- which user owns files and volumes;
- which ports are reachable and from where;
- how secrets are provisioned without Git;
- how readiness is checked;
- how the unit is rolled back;
- whether Portainer or systemd is the single lifecycle controller.

Do not manage one container from both Portainer and Quadlet. Choose one controller per workload to avoid competing updates and restarts.

## Services That Are Not Quadlet Units

The following components are deliberately host-managed:

| Component | Runtime | Configuration |
|---|---|---|
| Nginx | host systemd service | `/etc/nginx` |
| Fail2Ban | host systemd service | `/etc/fail2ban` |
| Certbot | host command and renewal timer | `/etc/letsencrypt` |
| Podman API | `doom` user systemd socket | `/run/user/UID/podman/podman.sock` |

This separation keeps the public Quadlet surface small and makes host access controls visible in ordinary systemd and package configuration.

## Publication Checklist

- Confirm every `deploy/*.container` file is intentional and documented.
- Confirm no private image registry credentials, passwords, tokens, certificates, or volumes are committed.
- Verify that each bind-mounted path exists after bootstrap or is created by the deployment process.
- Check that public ports are loopback or explicitly documented provider-firewall exceptions.
- Run Bash syntax checks and `git diff --check`.
- Test each unit on a disposable Debian/Ubuntu host before calling it production-ready.
