# Quadlet Services

## Scope

Quadlet converts Podman unit files into user systemd services. The node2 runtime belongs to the unprivileged `doom` account. The server bootstrap creates the user systemd manager, enables lingering, starts the rootless Podman socket, and creates the persistent `portainer_data` volume.

Node2 definitions are explicit and isolated from node1-only manifests:

```text
deploy/quadlet/node2/*.container -> matching *.service
deploy/quadlet/node2/dnsserver-quadlet.kube -> dnsserver-quadlet.service
deploy/quadlet/node1/alloy-node1.container -> excluded from node2 profile
```

Nginx and Fail2Ban are host services, not containers. Alloy, Loki, VictoriaMetrics, Nextcloud, 3X-UI, Open WebUI, DNS, Portainer, and Qdrant use rootless Quadlet definitions under `deploy/quadlet/node2/`.

## Portainer Container

Source file: [`deploy/quadlet/node2/portainer.container`](../deploy/quadlet/node2/portainer.container)

```ini
[Unit]
Description=Portainer CE 2.45.1 for rootless doom Podman
Wants=podman.socket
After=podman.socket

[Container]
Image=docker.io/portainer/portainer-ce:2.45.1
ContainerName=portainer
PublishPort=127.0.0.1:8080:8000
PublishPort=127.0.0.1:9443:9443
Volume=%t/podman/podman.sock:/var/run/docker.sock
Volume=portainer_data:/data

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

### `[Unit]`

`Wants=podman.socket` starts the rootless Podman API socket with the service. `After=podman.socket` orders the generated service after that socket. The socket is owned by the `doom` user systemd manager, not by the host root Podman service.

### `[Container]`

- `Image` pins the configured Portainer CE version. The image is pulled on the target and is not stored in Git.
- `ContainerName` gives the container a stable Podman name.
- `PublishPort=127.0.0.1:9443:9443` keeps Portainer private to the host. Use an SSH tunnel or a separately reviewed reverse proxy for access.
- `%t/podman/podman.sock` resolves to the runtime directory of `doom`, for example `/run/user/1001/podman/podman.sock`. It is mounted at `/var/run/docker.sock` because Portainer speaks Podman's Docker-compatible API.
- `portainer_data:/data` is a rootless named volume created by bootstrap. It holds the Portainer database and configuration.
- Portainer initializes its administrator on first access. Bootstrap does not create or print Portainer credentials.

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

The project deployment command uploads the selected unit, reloads the user manager, restarts the generated service, and checks its active state. Quadlet's `WantedBy=default.target` attaches it to the user default target; lingering starts that target after reboot. Portainer deployment waits for its HTTPS API, and SocratiCode Qdrant deployment waits for `http://127.0.0.1:6333/readyz`.

```fish
set -lx DEPLOY_CONFIRM YES
./scripts/deploy-node2.fish root@node2
```

## Adding Another Container

Add one reviewed file per workload under `deploy/`:

```text
deploy/quadlet/node2/SERVICE_NAME.container
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

- Confirm the service is listed in `deploy/profiles/node2-full.units` if it belongs in the node2 profile.
- Keep node1-specific units and unused compatibility definitions out of the node2 profile.
- Confirm no private image registry credentials, passwords, tokens, certificates, or volumes are committed.
- Verify that each bind-mounted path exists after bootstrap or is created by the deployment process.
- Check that public ports are loopback or explicitly documented provider-firewall exceptions.
- Run Bash syntax checks and `git diff --check`.
- Test each unit on a disposable Debian/Ubuntu host before calling it production-ready.
