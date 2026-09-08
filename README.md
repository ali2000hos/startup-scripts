# n8n — interactive installer

Sets up a production-ready [n8n](https://n8n.io) instance on a fresh Ubuntu server:
Docker, PostgreSQL 16, an external task runner, an Nginx reverse proxy with a
Let's Encrypt certificate, verified backups and safe updates.

## Usage

```bash
wget https://raw.githubusercontent.com/ali2000hos/startup-scripts/main/n8n/install-n8n.sh
sudo bash install-n8n.sh
```

The script is interactive, so it cannot be piped from `curl`. Re-running it is
safe: existing secrets and data are preserved.

## What it asks

| Question | Default | Notes |
|---|---|---|
| Domain | — | Falls back to an `sslip.io` name for testing |
| Let's Encrypt email | — | Expiry warnings; skipping means silent expiry |
| Timezone | detected | Used by schedule and cron nodes |
| n8n image tag | `stable` | Pin an exact version to avoid surprise upgrades |
| Queue mode | no | Adds Redis and a worker container |
| SMTP | no | For invites and password resets |
| Nightly backups | yes | 02:00, 7 day retention by default |
| Weekly updates | no | Backs up first, rolls back on failure |

## What gets installed

```
/opt/n8n/
├── .env                 secrets, including N8N_ENCRYPTION_KEY (chmod 600)
├── compose.yaml         postgres + n8n + runner (+ redis + worker)
├── init-data.sh         creates the non-root database user
├── backup.sh            database + data volume + .env, as one archive
├── restore.sh           full restore from a backup archive
├── update.sh            backup, pull, restart, roll back if unhealthy
├── n8nctl               management wrapper, symlinked to /usr/local/bin
├── CREDENTIALS.txt      summary (chmod 600)
├── backups/             chmod 700
└── local-files/         mounted at /files inside n8n
```

## Management

```bash
n8nctl status              # container status
n8nctl logs n8n            # follow a service log
n8nctl backup              # back up now
n8nctl backups             # list backups
n8nctl restore <archive>   # restore
n8nctl update              # update with backup and automatic rollback
n8nctl key                 # print the encryption key
```

## The encryption key

`N8N_ENCRYPTION_KEY` decrypts every credential stored in n8n. A database dump
without it is useless: workflows come back, credentials do not. The installer
prints it at the end and includes it in every backup archive — copy it somewhere
off the server.

## Notes

- Execution history is pruned after 14 days by default. Raise
  `EXECUTIONS_DATA_MAX_AGE` in `/opt/n8n/.env` to keep more.
- PostgreSQL is not exposed to the host; n8n listens on `127.0.0.1:5678` only.
- Certificate renewal is handled by certbot's systemd timer with an Nginx
  reload hook — no extra cron entry.
- Queue mode can be enabled later by re-running the script. The database is
  unchanged, so there is no migration.
- Test a restore on a throwaway server before you rely on the backups.

## Requirements

- Ubuntu (tested on recent LTS releases), root access
- A domain with an A record pointing at the server, for a real certificate
- ~2 GB RAM; the script offers to add swap below that
