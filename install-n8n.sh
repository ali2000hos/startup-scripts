#!/usr/bin/env bash
#
# Interactive n8n installer for a fresh Ubuntu server.
# Docker + PostgreSQL 16 + task runner (+ optional queue mode with Redis & worker)
# Nginx reverse proxy + Let's Encrypt TLS + backups + safe updates.
#
# Usage:  sudo bash install-n8n.sh
# Re-running is safe: existing secrets and data are preserved.
#
set -euo pipefail

# ------------------------------------------------------------------
# Presentation helpers
# ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}== $1 ==${NC}"; }

die() { log_error "$1"; exit 1; }

# Ask a free-text question with an optional default.
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}?${NC} ${prompt} [${CYAN}${default}${NC}]: ")" answer
    echo "${answer:-$default}"
  else
    read -rp "$(echo -e "${BOLD}?${NC} ${prompt}: ")" answer
    echo "$answer"
  fi
}

# Ask a yes/no question. $2 is the default ("y" or "n").
ask_yn() {
  local prompt="$1" default="${2:-n}" answer hint
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -rp "$(echo -e "${BOLD}?${NC} ${prompt} (${hint}): ")" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo "   Please answer y or n." ;;
    esac
  done
}

trap 'log_error "Failed at line $LINENO. Nothing further was changed."' ERR

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------
PROJECT_DIR="/opt/n8n"
BACKUP_DIR="${PROJECT_DIR}/backups"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
WEBROOT="/var/www/certbot"

# ------------------------------------------------------------------
log_step "Step 0: Preflight checks"
# ------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this script as root:  sudo bash $0"
[[ -t 0 ]] || die "This script is interactive. Download it first, then run it — do not pipe it from curl."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || log_warn "Tested on Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
  UBUNTU_CODENAME_DETECTED="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
else
  UBUNTU_CODENAME_DETECTED=""
fi

TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
log_info "Memory: ${TOTAL_MEM_MB} MB"
if (( TOTAL_MEM_MB < 1800 )); then
  log_warn "n8n with PostgreSQL wants ~2 GB RAM. You have ${TOTAL_MEM_MB} MB."
  if [[ ! -f /swapfile ]] && ask_yn "Create a 2 GB swap file to be safe?" "y"; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_success "2 GB swap enabled."
  fi
fi

# Public IP, used for the DNS sanity check and the sslip.io fallback.
SERVER_IP=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
  || hostname -I | awk '{print $1}')
[[ -n "$SERVER_IP" ]] || die "Could not determine the server IP address."
log_success "Server IP: ${SERVER_IP}"

# ------------------------------------------------------------------
log_step "Step 1: Configuration questions"
# ------------------------------------------------------------------

# --- Reuse an existing installation? -------------------------------
REUSED_ENV=false
if [[ -f "$ENV_FILE" ]]; then
  log_warn "An existing ${ENV_FILE} was found."
  echo "   It holds N8N_ENCRYPTION_KEY, which decrypts every stored credential."
  echo "   Regenerating it would make all existing credentials unreadable."
  if ask_yn "Keep the existing secrets and only update the configuration?" "y"; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
    REUSED_ENV=true
    log_success "Existing secrets loaded."
  else
    ask_yn "This DESTROYS access to existing credentials. Are you certain?" "n" \
      || die "Aborted by user. Nothing was changed."
    cp "$ENV_FILE" "${ENV_FILE}.replaced.$(date +%s)"
    log_warn "Old .env kept as ${ENV_FILE}.replaced.*"
  fi
fi

# --- Domain --------------------------------------------------------
echo ""
echo "  A real domain is strongly recommended. Webhook URLs are stored inside"
echo "  workflows and registered with third-party services, so changing the"
echo "  domain later means updating all of them by hand."
echo ""
if ask_yn "Do you have a domain pointing at ${SERVER_IP}?" "y"; then
  while true; do
    N8N_DOMAIN=$(ask "Domain for n8n (e.g. n8n.example.com)" "${N8N_DOMAIN:-}")
    if [[ "$N8N_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
      break
    fi
    log_warn "That does not look like a valid domain. Try again."
  done
else
  N8N_DOMAIN="n8n.${SERVER_IP//./-}.sslip.io"
  log_warn "Using ${N8N_DOMAIN} (sslip.io). Fine for testing, tied to this IP."
fi

# --- DNS sanity check ---------------------------------------------
log_info "Checking DNS for ${N8N_DOMAIN}..."
RESOLVED_IP=$(getent hosts "$N8N_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
if [[ -z "$RESOLVED_IP" ]]; then
  log_warn "${N8N_DOMAIN} does not resolve yet."
  echo "   Let's Encrypt will fail until an A record points to ${SERVER_IP}."
  ask_yn "Continue anyway?" "n" || die "Add the DNS record, then re-run this script."
elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
  log_warn "${N8N_DOMAIN} resolves to ${RESOLVED_IP}, not ${SERVER_IP}."
  echo "   If you use Cloudflare proxy, set the record to DNS-only during setup."
  ask_yn "Continue anyway?" "n" || die "Fix the DNS record, then re-run this script."
else
  log_success "DNS points here correctly."
fi

# --- Let's Encrypt contact address --------------------------------
echo ""
echo "  Let's Encrypt emails you when a certificate is close to expiring and"
echo "  renewal has failed. Skipping it means silent expiry."
while true; do
  LETSENCRYPT_EMAIL=$(ask "Email for certificate expiry notices" "${LETSENCRYPT_EMAIL:-}")
  if [[ "$LETSENCRYPT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]]; then
    break
  fi
  if [[ -z "$LETSENCRYPT_EMAIL" ]] && ask_yn "Really register without an email address?" "n"; then
    break
  fi
  log_warn "That does not look like a valid email address."
done

# --- Timezone ------------------------------------------------------
DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
GENERIC_TIMEZONE=$(ask "Timezone for schedules and cron nodes" "${GENERIC_TIMEZONE:-$DETECTED_TZ}")

# --- n8n version ---------------------------------------------------
echo ""
echo "  'stable' tracks the latest stable release. Pinning an exact version"
echo "  (e.g. 1.80.0) means no surprise upgrades on restart."
N8N_VERSION=$(ask "n8n image tag" "${N8N_VERSION:-stable}")

# --- Queue mode ----------------------------------------------------
echo ""
echo "  Queue mode adds Redis and a separate worker container. It keeps the"
echo "  editor responsive under heavy load and lets executions survive a"
echo "  restart of the main process. Not needed for light or moderate use —"
echo "  you can switch it on later without touching the database."
QUEUE_MODE=false
ask_yn "Enable queue mode (Redis + worker) now?" "n" && QUEUE_MODE=true

# --- SMTP ----------------------------------------------------------
echo ""
echo "  SMTP is what n8n uses for user invites and password resets."
echo "  It is unrelated to the free community licence key, which n8n's own"
echo "  servers email you from inside the UI."
SMTP_ENABLED=false
if ask_yn "Configure SMTP now?" "n"; then
  SMTP_ENABLED=true
  N8N_SMTP_HOST=$(ask "SMTP host" "${N8N_SMTP_HOST:-}")
  N8N_SMTP_PORT=$(ask "SMTP port (587 = STARTTLS, 465 = implicit TLS)" "${N8N_SMTP_PORT:-587}")
  N8N_SMTP_USER=$(ask "SMTP username" "${N8N_SMTP_USER:-}")
  read -rsp "$(echo -e "${BOLD}?${NC} SMTP password: ")" N8N_SMTP_PASS; echo ""
  N8N_SMTP_SENDER=$(ask "Sender address (must be verified with your provider)" "${N8N_SMTP_SENDER:-}")
  if [[ "$N8N_SMTP_PORT" == "465" ]]; then N8N_SMTP_SSL=true; else N8N_SMTP_SSL=false; fi
  log_info "N8N_SMTP_SSL set to ${N8N_SMTP_SSL} to match port ${N8N_SMTP_PORT}."
fi

# --- Maintenance ---------------------------------------------------
echo ""
BACKUP_ENABLED=true
ask_yn "Enable nightly backups at 02:00 (database + credential key + files)?" "y" \
  || BACKUP_ENABLED=false
BACKUP_RETAIN_DAYS=7
$BACKUP_ENABLED && BACKUP_RETAIN_DAYS=$(ask "Keep backups for how many days?" "7")

echo ""
echo "  Unattended updates pull the newest image on a schedule. This script's"
echo "  update job takes a backup first and rolls back if n8n fails to come up,"
echo "  but an update you are not watching is still an update you cannot debug."
AUTOUPDATE_ENABLED=false
ask_yn "Enable weekly automatic updates (Sunday 04:00)?" "n" && AUTOUPDATE_ENABLED=true

# --- Confirm -------------------------------------------------------
echo ""
echo -e "${BOLD}Summary${NC}"
echo "  Domain:         https://${N8N_DOMAIN}"
echo "  Certificate:    Let's Encrypt${LETSENCRYPT_EMAIL:+ (notices to ${LETSENCRYPT_EMAIL})}"
echo "  Timezone:       ${GENERIC_TIMEZONE}"
echo "  n8n version:    ${N8N_VERSION}"
echo "  Database:       PostgreSQL 16 (container, not exposed publicly)"
echo "  Queue mode:     $($QUEUE_MODE && echo 'yes (Redis + worker)' || echo 'no')"
echo "  SMTP:           $($SMTP_ENABLED && echo 'configured' || echo 'not configured')"
echo "  Backups:        $($BACKUP_ENABLED && echo "nightly 02:00, ${BACKUP_RETAIN_DAYS} day retention" || echo 'manual only')"
echo "  Auto-update:    $($AUTOUPDATE_ENABLED && echo 'weekly, Sunday 04:00' || echo 'manual only')"
echo "  Install path:   ${PROJECT_DIR}"
echo ""
ask_yn "Proceed with installation?" "y" || die "Aborted. Nothing was changed."

# ------------------------------------------------------------------
log_step "Step 2: Installing Docker"
# ------------------------------------------------------------------
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  log_warn "Docker already present: $(docker --version)"
else
  log_info "Installing Docker Engine and the compose plugin..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Docker's repo sometimes lags a brand-new Ubuntu release. Fall back to the
  # newest codename that actually has a package index.
  CODENAME="${UBUNTU_CODENAME_DETECTED:-$(lsb_release -cs)}"
  if ! curl -fsSI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1; then
    log_warn "Docker has no repository for '${CODENAME}' yet — falling back to 'noble'."
    CODENAME="noble"
  fi

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log_success "Docker installed."
fi

# Cap container log growth so a chatty workflow cannot fill the disk.
if [[ ! -f /etc/docker/daemon.json ]]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'DOCKERJSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
DOCKERJSON
  systemctl restart docker
  log_success "Docker log rotation configured (10 MB x 3 per container)."
fi

# ------------------------------------------------------------------
log_step "Step 3: Creating project structure"
# ------------------------------------------------------------------
mkdir -p "${PROJECT_DIR}/local-files" "${BACKUP_DIR}" "${WEBROOT}"
chmod 700 "${BACKUP_DIR}"
log_success "Project directory ready at ${PROJECT_DIR}"

# ------------------------------------------------------------------
log_step "Step 4: Writing .env"
# ------------------------------------------------------------------
gen_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 40; }

# Only generate what we do not already have, so re-runs never rotate the
# encryption key or the database password out from under existing data.
POSTGRES_USER="${POSTGRES_USER:-n8n_root}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
POSTGRES_NON_ROOT_USER="${POSTGRES_NON_ROOT_USER:-n8n_user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(gen_secret)}"
POSTGRES_NON_ROOT_PASSWORD="${POSTGRES_NON_ROOT_PASSWORD:-$(gen_secret)}"
RUNNERS_AUTH_TOKEN="${RUNNERS_AUTH_TOKEN:-$(gen_secret)}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(gen_secret)}"

{
  echo "# n8n configuration — generated $(date -Iseconds)"
  echo "# WARNING: N8N_ENCRYPTION_KEY decrypts every stored credential."
  echo "# Losing it makes every credential in n8n permanently unreadable."
  echo ""
  echo "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}"
  echo ""
  echo "POSTGRES_USER=${POSTGRES_USER}"
  echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
  echo "POSTGRES_DB=${POSTGRES_DB}"
  echo "POSTGRES_NON_ROOT_USER=${POSTGRES_NON_ROOT_USER}"
  echo "POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_NON_ROOT_PASSWORD}"
  echo ""
  echo "N8N_VERSION=${N8N_VERSION}"
  echo "N8N_DOMAIN=${N8N_DOMAIN}"
  echo "WEBHOOK_URL=https://${N8N_DOMAIN}/"
  echo "N8N_EDITOR_BASE_URL=https://${N8N_DOMAIN}/"
  echo "N8N_PROTOCOL=https"
  echo "N8N_SECURE_COOKIE=true"
  echo "N8N_PROXY_HOPS=1"
  echo "GENERIC_TIMEZONE=${GENERIC_TIMEZONE}"
  echo "TZ=${GENERIC_TIMEZONE}"
  echo ""
  echo "RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}"
  echo "EXECUTIONS_DATA_PRUNE=true"
  echo "EXECUTIONS_DATA_MAX_AGE=336"
  echo "N8N_DIAGNOSTICS_ENABLED=false"
  if $QUEUE_MODE; then
    echo ""
    echo "EXECUTIONS_MODE=queue"
    echo "QUEUE_BULL_REDIS_HOST=redis"
    echo "QUEUE_HEALTH_CHECK_ACTIVE=true"
  fi
  if $SMTP_ENABLED; then
    echo ""
    echo "N8N_EMAIL_MODE=smtp"
    echo "N8N_SMTP_HOST=${N8N_SMTP_HOST}"
    echo "N8N_SMTP_PORT=${N8N_SMTP_PORT}"
    echo "N8N_SMTP_USER=${N8N_SMTP_USER}"
    echo "N8N_SMTP_PASS=${N8N_SMTP_PASS}"
    echo "N8N_SMTP_SENDER=${N8N_SMTP_SENDER}"
    echo "N8N_SMTP_SSL=${N8N_SMTP_SSL}"
  fi
} > "$ENV_FILE"

chmod 600 "$ENV_FILE"
$REUSED_ENV && log_success ".env updated, existing secrets preserved." \
            || log_success ".env created with fresh secrets."

# ------------------------------------------------------------------
log_step "Step 5: Database init script"
# ------------------------------------------------------------------
# Runs only on first start, when the data volume is empty.
cat > "${PROJECT_DIR}/init-data.sh" <<'INITEOF'
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_NON_ROOT_USER}') THEN
        CREATE ROLE ${POSTGRES_NON_ROOT_USER} LOGIN PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
      END IF;
    END
    \$\$;
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
    GRANT ALL ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
    ALTER SCHEMA public OWNER TO ${POSTGRES_NON_ROOT_USER};
EOSQL
INITEOF
chmod +x "${PROJECT_DIR}/init-data.sh"
log_success "Database init script written."

# ------------------------------------------------------------------
log_step "Step 6: Writing compose.yaml"
# ------------------------------------------------------------------
cat > "$COMPOSE_FILE" <<'COMPOSEEOF'
volumes:
  db_storage:
    name: n8n_db_storage
  n8n_storage:
    name: n8n_app_storage
  redis_storage:
    name: n8n_redis_storage

networks:
  n8n_net:
    name: n8n_net

x-n8n-common: &n8n-common
  image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
  restart: unless-stopped
  environment:
    - DB_TYPE=postgresdb
    - DB_POSTGRESDB_HOST=postgres
    - DB_POSTGRESDB_PORT=5432
    - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
    - DB_POSTGRESDB_USER=${POSTGRES_NON_ROOT_USER}
    - DB_POSTGRESDB_PASSWORD=${POSTGRES_NON_ROOT_PASSWORD}
    - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    - N8N_HOST=${N8N_DOMAIN}
    - N8N_PROTOCOL=${N8N_PROTOCOL}
    - N8N_PROXY_HOPS=${N8N_PROXY_HOPS}
    - N8N_SECURE_COOKIE=${N8N_SECURE_COOKIE}
    - WEBHOOK_URL=${WEBHOOK_URL}
    - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
    - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    - TZ=${TZ}
    - EXECUTIONS_DATA_PRUNE=${EXECUTIONS_DATA_PRUNE}
    - EXECUTIONS_DATA_MAX_AGE=${EXECUTIONS_DATA_MAX_AGE}
    - N8N_DIAGNOSTICS_ENABLED=${N8N_DIAGNOSTICS_ENABLED}
    - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
    - N8N_RUNNERS_ENABLED=true
    - N8N_RUNNERS_MODE=external
    - N8N_RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
    - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
  volumes:
    - n8n_storage:/home/node/.n8n
    - ./local-files:/files
  networks:
    - n8n_net

services:
  postgres:
    image: postgres:16
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER
      - POSTGRES_PASSWORD
      - POSTGRES_DB
      - POSTGRES_NON_ROOT_USER
      - POSTGRES_NON_ROOT_PASSWORD
    volumes:
      - db_storage:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh:ro
    networks:
      - n8n_net
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s

  n8n:
    <<: *n8n-common
    container_name: n8n_app
    ports:
      - "127.0.0.1:5678:5678"
    depends_on:
      postgres:
        condition: service_healthy

  n8n-runner:
    image: n8nio/runners:${N8N_VERSION}
    container_name: n8n_runner
    restart: unless-stopped
    environment:
      - N8N_RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
      - N8N_RUNNERS_TASK_BROKER_URI=http://n8n:5679
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - TZ=${TZ}
    networks:
      - n8n_net
    depends_on:
      - n8n
COMPOSEEOF

if $QUEUE_MODE; then
  cat >> "$COMPOSE_FILE" <<'QUEUEEOF'

  redis:
    image: redis:7-alpine
    container_name: n8n_redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_storage:/data
    networks:
      - n8n_net
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 5s
      retries: 10

  n8n-worker:
    <<: *n8n-common
    container_name: n8n_worker
    command: worker
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
QUEUEEOF

  # Queue variables belong on every n8n process, main and worker alike.
  # The encryption key is already shared through the YAML anchor above —
  # a mismatch there is the classic cause of "workers cannot decrypt credentials".
  python3 - "$COMPOSE_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "    - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0\n"
extra = ("    - EXECUTIONS_MODE=${EXECUTIONS_MODE}\n"
         "    - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}\n"
         "    - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}\n")
open(path, "w").write(text.replace(anchor, anchor + extra, 1))
PYEOF
  log_success "compose.yaml written (queue mode: Redis + worker)."
else
  log_success "compose.yaml written."
fi

if $SMTP_ENABLED; then
  python3 - "$COMPOSE_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "    - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0\n"
extra = ("    - N8N_EMAIL_MODE=${N8N_EMAIL_MODE}\n"
         "    - N8N_SMTP_HOST=${N8N_SMTP_HOST}\n"
         "    - N8N_SMTP_PORT=${N8N_SMTP_PORT}\n"
         "    - N8N_SMTP_USER=${N8N_SMTP_USER}\n"
         "    - N8N_SMTP_PASS=${N8N_SMTP_PASS}\n"
         "    - N8N_SMTP_SENDER=${N8N_SMTP_SENDER}\n"
         "    - N8N_SMTP_SSL=${N8N_SMTP_SSL}\n")
open(path, "w").write(text.replace(anchor, anchor + extra, 1))
PYEOF
  log_success "SMTP settings added to compose.yaml."
fi

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q \
  && log_success "compose.yaml validated."

# ------------------------------------------------------------------
log_step "Step 7: Firewall"
# ------------------------------------------------------------------
if command -v ufw &>/dev/null; then
  SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo 22)
  ufw allow "${SSH_PORT}/tcp" >/dev/null   # allowed FIRST, so enabling never locks you out
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  log_success "UFW enabled (SSH ${SSH_PORT}, 80, 443). PostgreSQL is not exposed."
else
  log_warn "UFW not installed — skipping firewall configuration."
fi

# ------------------------------------------------------------------
log_step "Step 8: Nginx and TLS certificate"
# ------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq nginx certbot
systemctl enable --now nginx >/dev/null

# HTTP-only config first, so certbot's webroot challenge can be served.
cat > /etc/nginx/sites-available/n8n <<NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${N8N_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXHTTP
ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null && systemctl reload nginx

if [[ -d "/etc/letsencrypt/live/${N8N_DOMAIN}" ]]; then
  log_warn "Certificate for ${N8N_DOMAIN} already exists — reusing it."
else
  log_info "Requesting certificate for ${N8N_DOMAIN}..."
  CERTBOT_ARGS=(certonly --webroot -w "${WEBROOT}" -d "${N8N_DOMAIN}"
                --non-interactive --agree-tos --no-eff-email)
  if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
    CERTBOT_ARGS+=(-m "$LETSENCRYPT_EMAIL")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi
  if ! certbot "${CERTBOT_ARGS[@]}"; then
    log_error "Certificate request failed. Common causes:"
    echo "   - DNS for ${N8N_DOMAIN} does not point at ${SERVER_IP} yet"
    echo "   - Port 80 blocked upstream (cloud provider firewall, not just UFW)"
    echo "   - Let's Encrypt rate limit hit (5 failures per hour per domain)"
    echo "   Fix the cause and re-run this script — everything else is already in place."
    exit 1
  fi
  log_success "Certificate obtained."
fi

# Full HTTPS reverse proxy config.
cat > /etc/nginx/sites-available/n8n <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${N8N_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${N8N_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${N8N_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${N8N_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Workflows can receive large webhook payloads and file uploads.
    client_max_body_size 100m;

    location / {
        proxy_pass         http://127.0.0.1:5678;
        proxy_http_version 1.1;

        # The editor uses WebSockets for live execution feedback.
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";

        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-Forwarded-Host \$host;

        proxy_buffering    off;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINXEOF
nginx -t >/dev/null && systemctl reload nginx
log_success "Nginx reverse proxy configured."

# Renewal: the certbot package ships a systemd timer that runs twice a day.
# A deploy hook is all that is needed on top of it — no extra cron entry.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOKEOF'
#!/bin/bash
systemctl reload nginx
HOOKEOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if systemctl list-timers 2>/dev/null | grep -q certbot; then
  log_success "Renewal handled by certbot's systemd timer, with an nginx reload hook."
else
  log_warn "No certbot timer found — registering a renewal cron entry instead."
  echo "0 3,15 * * * root certbot renew --quiet" > /etc/cron.d/n8n-certbot-renew
fi

# ------------------------------------------------------------------
log_step "Step 9: Backup tooling"
# ------------------------------------------------------------------
cat > "${PROJECT_DIR}/backup.sh" <<'BACKUPEOF'
#!/usr/bin/env bash
# Backs up everything needed for a full restore:
#   - the PostgreSQL database (workflows, executions, encrypted credentials)
#   - the n8n data volume (settings, the encryption key if n8n generated one)
#   - the .env file (the encryption key and all passwords)
# A database dump alone is NOT a usable backup: without the key, every
# stored credential is permanently undecryptable.
set -euo pipefail

PROJECT_DIR="/opt/n8n"
BACKUP_DIR="${PROJECT_DIR}/backups"
LOG_FILE="/var/log/n8n-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
RETAIN_DAYS="${RETAIN_DAYS:-7}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

set -a; . "${PROJECT_DIR}/.env"; set +a

mkdir -p "$BACKUP_DIR"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

log "===================================="
log "Starting backup ${TIMESTAMP}"

docker exec n8n_postgres pg_dump -U "$POSTGRES_NON_ROOT_USER" "$POSTGRES_DB" \
  > "${STAGING}/database.sql"
log "Database dumped ($(du -h "${STAGING}/database.sql" | cut -f1))."

docker run --rm -v n8n_app_storage:/data:ro -v "${STAGING}":/out alpine \
  tar czf /out/n8n-data.tar.gz -C /data . 2>/dev/null
log "Data volume archived."

cp "${PROJECT_DIR}/.env" "${STAGING}/env.backup"
cp "${PROJECT_DIR}/compose.yaml" "${STAGING}/compose.yaml"
[ -d "${PROJECT_DIR}/local-files" ] && \
  tar czf "${STAGING}/local-files.tar.gz" -C "${PROJECT_DIR}" local-files

ARCHIVE="${BACKUP_DIR}/n8n_backup_${TIMESTAMP}.tar.gz"
tar czf "$ARCHIVE" -C "$STAGING" .
chmod 600 "$ARCHIVE"

if [ ! -s "$ARCHIVE" ]; then
  log "ERROR: backup archive is empty or missing."
  exit 1
fi
log "Backup written: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"

DELETED=$(find "$BACKUP_DIR" -name 'n8n_backup_*.tar.gz' -mtime "+${RETAIN_DAYS}" -print -delete | wc -l)
[ "$DELETED" -gt 0 ] && log "Removed ${DELETED} backup(s) older than ${RETAIN_DAYS} days."

log "Backup completed."
log "===================================="
BACKUPEOF
chmod +x "${PROJECT_DIR}/backup.sh"

cat > "${PROJECT_DIR}/restore.sh" <<'RESTOREEOF'
#!/usr/bin/env bash
# Restores from an archive produced by backup.sh.
# Usage: bash /opt/n8n/restore.sh /opt/n8n/backups/n8n_backup_YYYY-MM-DD_HH-MM-SS.tar.gz
set -euo pipefail

PROJECT_DIR="/opt/n8n"
ARCHIVE="${1:-}"

[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "Usage: $0 <backup-archive.tar.gz>"; exit 1; }

echo "This overwrites the current database and n8n data volume."
read -rp "Type RESTORE to continue: " confirm
[ "$confirm" = "RESTORE" ] || { echo "Aborted."; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
tar xzf "$ARCHIVE" -C "$STAGING"

# The .env from the backup carries the encryption key that matches this data.
cp "${STAGING}/env.backup" "${PROJECT_DIR}/.env"
chmod 600 "${PROJECT_DIR}/.env"
set -a; . "${PROJECT_DIR}/.env"; set +a

# n8n must be down: open connections block DROP DATABASE.
docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" \
  stop n8n n8n-worker n8n-runner 2>/dev/null || true
docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" \
  up -d postgres

echo "Waiting for PostgreSQL..."
for _ in $(seq 1 30); do
  docker exec n8n_postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 && break
  sleep 2
done

docker exec -i n8n_postgres psql -U "$POSTGRES_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};" -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_NON_ROOT_USER};"
docker exec -i n8n_postgres psql -U "$POSTGRES_NON_ROOT_USER" -d "$POSTGRES_DB" \
  < "${STAGING}/database.sql"
echo "Database restored."

docker run --rm -v n8n_app_storage:/data -v "${STAGING}":/in alpine \
  sh -c "rm -rf /data/* && tar xzf /in/n8n-data.tar.gz -C /data"
echo "Data volume restored."

docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" up -d
echo "Restore complete. Check: docker compose -f ${PROJECT_DIR}/compose.yaml logs -f n8n"
RESTOREEOF
chmod +x "${PROJECT_DIR}/restore.sh"
log_success "backup.sh and restore.sh written."

# ------------------------------------------------------------------
log_step "Step 10: Update tooling"
# ------------------------------------------------------------------
cat > "${PROJECT_DIR}/update.sh" <<'UPDATEEOF'
#!/usr/bin/env bash
# Pulls newer images and restarts. Takes a backup first and rolls back to the
# previous image if n8n does not become healthy within the timeout.
set -euo pipefail

PROJECT_DIR="/opt/n8n"
COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
ENV_FILE="${PROJECT_DIR}/.env"
LOG_FILE="/var/log/n8n-update.log"
HEALTH_TIMEOUT=120

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

set -a; . "$ENV_FILE"; set +a
IMAGE="docker.n8n.io/n8nio/n8n:${N8N_VERSION}"

log "===================================="
log "Checking for updates..."

BEFORE=$(docker image inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo none)
compose pull >> "$LOG_FILE" 2>&1
AFTER=$(docker image inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo none)

if [ "$BEFORE" = "$AFTER" ]; then
  log "Already up to date."
  exit 0
fi

log "New image found: ${AFTER:7:19}"
log "Taking a backup before updating..."
bash "${PROJECT_DIR}/backup.sh" >> "$LOG_FILE" 2>&1 || {
  log "ERROR: backup failed — update aborted. Nothing was changed."
  exit 1
}

# Tag the old image so a rollback has something to point at.
if [ "$BEFORE" != "none" ]; then
  docker tag "$BEFORE" n8n-rollback:previous
fi

log "Restarting with the new image..."
compose up -d >> "$LOG_FILE" 2>&1

log "Waiting for n8n to respond (up to ${HEALTH_TIMEOUT}s)..."
ELAPSED=0
until curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null 2>&1; do
  sleep 5; ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge "$HEALTH_TIMEOUT" ]; then
    log "ERROR: n8n did not come up. Rolling back."
    if docker image inspect n8n-rollback:previous >/dev/null 2>&1; then
      docker tag n8n-rollback:previous "$IMAGE"
      compose up -d >> "$LOG_FILE" 2>&1
      log "Rolled back to the previous image. Check: compose logs n8n"
    else
      log "No previous image to roll back to. Restore manually with restore.sh."
    fi
    exit 1
  fi
done

log "Update successful — n8n is responding."
docker image prune -f >> "$LOG_FILE" 2>&1
log "===================================="
UPDATEEOF
chmod +x "${PROJECT_DIR}/update.sh"

cat > "${PROJECT_DIR}/n8nctl" <<'CTLEOF'
#!/usr/bin/env bash
# Small management wrapper. Run: n8nctl <command>
set -euo pipefail
PROJECT_DIR="/opt/n8n"
compose() { docker compose -f "${PROJECT_DIR}/compose.yaml" --env-file "${PROJECT_DIR}/.env" "$@"; }

case "${1:-}" in
  start)    compose up -d ;;
  stop)     compose stop ;;
  restart)  compose restart ;;
  status)   compose ps ;;
  logs)     compose logs -f "${2:-}" ;;
  update)   bash "${PROJECT_DIR}/update.sh" ;;
  backup)   bash "${PROJECT_DIR}/backup.sh" ;;
  restore)  bash "${PROJECT_DIR}/restore.sh" "${2:-}" ;;
  backups)  ls -lh "${PROJECT_DIR}/backups" 2>/dev/null || echo "No backups yet." ;;
  key)      grep '^N8N_ENCRYPTION_KEY=' "${PROJECT_DIR}/.env" ;;
  *)
    cat <<USAGE

  n8nctl <command>

    start | stop | restart | status   service control
    logs [service]                    follow logs (n8n, postgres, n8n-worker...)
    update                            backup, pull, restart, roll back on failure
    backup                            run a backup now
    backups                           list stored backups
    restore <archive.tar.gz>          restore from a backup
    key                               print the encryption key

USAGE
    ;;
esac
CTLEOF
chmod +x "${PROJECT_DIR}/n8nctl"
ln -sf "${PROJECT_DIR}/n8nctl" /usr/local/bin/n8nctl
log_success "update.sh and the n8nctl helper are installed."

# ------------------------------------------------------------------
log_step "Step 11: Scheduled jobs"
# ------------------------------------------------------------------
# System cron files under /etc/cron.d are idempotent and easy to inspect,
# unlike appending to the root crontab.
if $BACKUP_ENABLED; then
  cat > /etc/cron.d/n8n-backup <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root RETAIN_DAYS=${BACKUP_RETAIN_DAYS} /opt/n8n/backup.sh >> /var/log/n8n-backup.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/n8n-backup
  log_success "Nightly backup scheduled for 02:00 (${BACKUP_RETAIN_DAYS} day retention)."
else
  rm -f /etc/cron.d/n8n-backup
  log_warn "Automatic backups disabled. Run them with: n8nctl backup"
fi

if $AUTOUPDATE_ENABLED; then
  cat > /etc/cron.d/n8n-update <<'CRONEOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root /opt/n8n/update.sh >> /var/log/n8n-update.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/n8n-update
  log_success "Weekly update scheduled for Sunday 04:00 (backup first, rollback on failure)."
else
  rm -f /etc/cron.d/n8n-update
  log_warn "Automatic updates disabled. Update with: n8nctl update"
fi

cat > /etc/logrotate.d/n8n <<'LOGROTATEEOF'
/var/log/n8n-*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
LOGROTATEEOF

# ------------------------------------------------------------------
log_step "Step 12: Starting services"
# ------------------------------------------------------------------
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

log_info "Waiting for n8n to become available..."
ELAPSED=0
until curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null 2>&1; do
  sleep 5; ELAPSED=$((ELAPSED + 5))
  if (( ELAPSED >= 180 )); then
    log_error "n8n did not respond within 180s."
    echo "   Inspect the logs with:  n8nctl logs n8n"
    exit 1
  fi
done
log_success "n8n is responding."

if $QUEUE_MODE; then
  sleep 5
  if docker logs n8n_worker 2>&1 | tail -30 | grep -qi 'error'; then
    log_warn "The worker log contains errors — check with: n8nctl logs n8n-worker"
  else
    log_success "Worker container started."
  fi
fi

# ------------------------------------------------------------------
# Credentials summary
# ------------------------------------------------------------------
cat > "${PROJECT_DIR}/CREDENTIALS.txt" <<CREDEOF
n8n installation — $(date -Iseconds)

URL:              https://${N8N_DOMAIN}
Install path:     ${PROJECT_DIR}

ENCRYPTION KEY (store this somewhere outside this server):
${N8N_ENCRYPTION_KEY}

Without this key, a database backup cannot decrypt any stored credential.
Every backup archive contains a copy, which is why ${BACKUP_DIR} is 0700
and the archives are 0600.

PostgreSQL app user:  ${POSTGRES_NON_ROOT_USER}
PostgreSQL password:  ${POSTGRES_NON_ROOT_PASSWORD}
PostgreSQL database:  ${POSTGRES_DB}
CREDEOF
chmod 600 "${PROJECT_DIR}/CREDENTIALS.txt"

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  n8n is running${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  URL:          ${CYAN}https://${N8N_DOMAIN}${NC}"
echo -e "  Owner setup:  ${CYAN}open the URL and create the owner account now${NC}"
echo -e "  Licence key:  ${CYAN}Settings > Usage and plan > Unlock paid features${NC}"
echo ""
echo -e "${BOLD}${YELLOW}  Save this encryption key off the server, today:${NC}"
echo -e "  ${BOLD}${N8N_ENCRYPTION_KEY}${NC}"
echo -e "  ${CYAN}Also stored in ${PROJECT_DIR}/CREDENTIALS.txt (chmod 600)${NC}"
echo ""
echo -e "${BOLD}Management${NC}"
echo -e "  ${CYAN}n8nctl status${NC}              container status"
echo -e "  ${CYAN}n8nctl logs n8n${NC}            follow the n8n log"
echo -e "  ${CYAN}n8nctl backup${NC}              back up now"
echo -e "  ${CYAN}n8nctl backups${NC}             list backups"
echo -e "  ${CYAN}n8nctl restore <file>${NC}      restore from a backup"
echo -e "  ${CYAN}n8nctl update${NC}              update with backup and rollback"
echo ""
echo -e "${BOLD}Scheduled${NC}"
echo -e "  Backups:      $($BACKUP_ENABLED && echo "daily 02:00, ${BACKUP_RETAIN_DAYS} day retention" || echo 'disabled')"
echo -e "  Updates:      $($AUTOUPDATE_ENABLED && echo 'Sunday 04:00' || echo 'disabled (manual)')"
echo -e "  TLS renewal:  certbot systemd timer, reloads nginx automatically"
echo ""
if ! $BACKUP_ENABLED; then
  log_warn "Backups are off. Turn them on later by re-running this script."
fi
echo -e "${CYAN}Tip: run 'n8nctl backup' now and copy the archive off this server,${NC}"
echo -e "${CYAN}then practise a restore before you depend on it.${NC}"
echo ""
