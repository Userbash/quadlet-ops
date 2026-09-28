# Security

## Access Model

- Operator scripts currently use SSH as root because they install packages and manage host files and services. Protect the SSH key, restrict its source addresses at the provider firewall, and avoid password-based automation.
- The `doom` account is for rootless containers and owns its Podman socket and application data. Do not add it to `sudo`, `wheel`, or privileged host groups.
- Portainer can control every container and file accessible to the `doom` Podman account. Treat its administrator credentials as sensitive infrastructure credentials.
- The Portainer Quadlet binds HTTPS to loopback. Use SSH forwarding or put it behind a separately reviewed TLS proxy. Do not expose the Podman socket over TCP.
- Rootless Portainer support is not officially guaranteed. Do not use this optional integration as a security boundary or assume complete feature compatibility.

## Secrets and Backups

- Never commit `.env`, SSH keys, TLS keys, tokens, database files, logs, or backup archives.
- Keep `.env` mode `600`; scripts source it as trusted Bash code.
- Do not put application secrets in Compose or Quadlet files. Store them in protected files on the server with ownership and mode restricted to the service account that needs them.
- Backups contain host configuration and may include sensitive details. Encrypt them, restrict access, and test restores.
- Current backups omit live database contents, uploads, and container storage. This is not a complete application backup strategy.

## Change Boundaries

- `backup` and `validate` are intended to be read-only on the target.
- `bootstrap`, `deploy`, `restore`, and `activate` require `DEPLOY_CONFIRM=YES`.
- Restore writes archived paths directly to the server. Inspect archives and make a fresh backup first.
- Bootstrap does not change SSH, DNS, TLS, or firewall configuration. Review and apply those separately so remote access is not accidentally lost.
- GitHub Actions validates and packages public files only. It has no production credentials and never deploys to a server.
- Bootstrap generates the Portainer administrator credential on the target. The bcrypt hash is readable by `doom`; the plaintext credential file is root-owned and mode `0600`. It is not placed in `.env`, Git, CI, or command output.
- The ACME private key remains under `/etc/letsencrypt` on the server and is excluded from Git and public bundles.
