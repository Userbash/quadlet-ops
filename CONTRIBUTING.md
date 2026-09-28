# Contributing

1. Do not add secrets, production logs, customer IP addresses, or backup archives.
2. Run `bash -n scripts/*.sh scripts/lib/*.sh` after shell changes.
3. Document new operator variables in `.env.example` and this README.
4. Keep read-only operations separate from server-changing operations.
5. Do not add automatic production deployment to GitHub Actions.

Pull requests should describe affected services, validation performed, and rollback steps. Update the operations and security documentation when a change affects server state, privileges, network exposure, or backups.
