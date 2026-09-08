# startup-scripts

Provisioning scripts for fresh servers. Each directory holds one self-contained
script and its own README.

| Script | Description |
|---|---|
| [`server-bootstrap/`](server-bootstrap/) | First-boot setup for a fresh server: updates, sudo user, key-only SSH, UFW, fail2ban, automatic patches, swap |
| [`n8n/`](n8n/) | n8n with PostgreSQL, task runner, Nginx + Let's Encrypt, backups and safe updates |

Run `server-bootstrap` first on a new machine, then whichever service script you need.

## Conventions

- One directory per service, with a `README.md` covering usage and what gets installed.
- Scripts are interactive and idempotent: re-running them preserves existing data and secrets.
- `set -euo pipefail` everywhere; every script passes `shellcheck -S warning`.
- Nothing is destroyed without an explicit confirmation prompt.
