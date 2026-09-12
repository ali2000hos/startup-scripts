# startup-scripts

Interactive setup scripts for fresh Linux servers. Each one asks what it needs,
explains the trade-off behind the riskier choices, and refuses to do anything
destructive without confirmation.

These exist because server setup is the kind of task you do rarely enough to
forget the details, but often enough that redoing it by hand every time is
wasteful — and the mistakes are expensive. A firewall enabled before the SSH
rule is added locks you out. A database backup without the encryption key
restores workflows whose credentials no longer decrypt. These scripts encode
the fixes for those specific failures.

## Scripts

| Script | What it sets up |
|---|---|
| [`bootstrap-server.sh`](bootstrap-server.sh) | Updates, sudo user, key-only SSH, UFW, fail2ban, automatic security patches, swap, kernel hardening |
| [`install-n8n.sh`](install-n8n.sh) | n8n with PostgreSQL, task runner, Nginx + Let's Encrypt, verified backups, safe updates |

On a new machine, run `bootstrap-server.sh` first, then whichever service you need.

## Quick start

```bash
# 1. Harden the server
wget https://raw.githubusercontent.com/ali2000hos/startup-scripts/main/bootstrap-server.sh
sudo bash bootstrap-server.sh

# 2. Confirm you can still log in from a second terminal, then:
sudo ssh-confirm

# 3. Install a service
wget https://raw.githubusercontent.com/ali2000hos/startup-scripts/main/install-n8n.sh
sudo bash install-n8n.sh
```

Each script documents its own prompts and behavior in its header comment —
open it before running.

## Design rules

Every script in this repo follows these. They are not style preferences — each
one comes from a specific way server setup goes wrong.

**Interactive, never piped from curl.** The scripts read from a terminal and
refuse to run without one. `curl | bash` gives you no chance to review what is
about to happen to a machine you care about.

**Idempotent.** Re-running preserves existing users, keys, secrets, data and
firewall rules. Nothing rotates a password or regenerates an encryption key
behind your back on the second run.

**Nothing destroyed without confirmation.** Any step that could lose data asks
first, and says plainly what would be lost.

**Reversible where it matters.** Config files are backed up before being
modified. SSH hardening arms an automatic rollback. Updates take a backup first
and roll back if the service fails its health check.

**Firewall and SSH ordering is deliberate.** SSH is allowed through UFW before
UFW is enabled. Password authentication is only disabled after a working key is
verified in place. `sshd -t` validates before any restart.

**Backups are complete or they are not backups.** A database dump alone does not
restore a working service. The n8n backup includes the database, the data
volume, and the encryption key, because two of those three are useless without
the others.

**`set -euo pipefail`, and every script passes `shellcheck -S warning` clean.**

## Requirements

- Ubuntu, recent LTS releases (tested on 22.04, 24.04 and newer)
- Root access
- For TLS: a domain with an A record pointing at the server

## Testing

Before running anything here against a server you care about, run it on a
throwaway VM. That applies to any setup script you find online, including these.
The scripts print what they will do and wait for confirmation, which makes a dry
run cheap.

For the backup functionality specifically: take a backup, then practise a
restore on a second server. An untested backup is a guess.

## Contributing

Issues and pull requests are welcome. If you are adding a script:

- One directory per service, with its own `README.md`
- Follow the design rules above
- Run `shellcheck -S warning your-script.sh` before opening the PR
- Add a row to the table in this file

## License

MIT — see [LICENSE](LICENSE). Use these however you like; they come with no
warranty, and you are responsible for what happens on your own servers.
