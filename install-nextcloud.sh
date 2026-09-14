#!/bin/bash
# install-nextcloud.sh -- version: 1.0.0
#
# Non-interactive Nextcloud installer for a fresh Ubuntu server.
# PHP 8.3 + Apache + PostgreSQL + Redis, coturn (Talk TURN), a high-performance
# backend (Talk signaling), Docker stack (Imaginary, Elasticsearch, Whiteboard,
# Talk Recording, Euro-Office, HaRP), Let's Encrypt TLS, optional S3 primary
# storage, backups and safe updates.
#
# Usage:  sudo bash install-nextcloud.sh
# Re-running is safe: existing secrets, data and the installed site are preserved.
set -eo pipefail


SUBDOMAIN_PREFIX="nxclf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}== $1 ==${NC}"; }

# -- Guard: root ----------------------------------------------
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root: sudo bash $0"
  exit 1
fi

# -- Guard: Ubuntu only ---------------------------------------
OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2)
OS_VER=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)

if [[ "$OS_ID" != "ubuntu" ]]; then
  log_error "This script requires Ubuntu. Detected: ${OS_ID}"
  exit 1
fi

if [[ "$OS_MAJOR" -lt 22 ]]; then
  log_warn "Ubuntu ${OS_VER} is older than 22.04. Continuing but not officially supported."
fi

log_info "Detected: Ubuntu ${OS_VER}"

# -- Paths ----------------------------------------------------
PROJECT_DIR="/opt/nextcloud"
NCWWW_DIR="/var/www/nextcloud"
NCDATA_DIR="/var/nextcloud-data"
BACKUP_DIR="${PROJECT_DIR}/backups"
LOG_DIR="/var/log/nextcloud"
DETECTED_TZ=$(cat /etc/timezone 2>/dev/null \
  || timedatectl show -p Timezone --value 2>/dev/null \
  || echo "UTC")

# -- Timer ----------------------------------------------------
SECONDS=0
elapsed() { printf "%dm %ds" "$((SECONDS/60))" "$((SECONDS%60))"; }

mkdir -p "${PROJECT_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"

# -- Reuse settings from a previous run (idempotent re-runs) ---
[[ -f "${PROJECT_DIR}/.env" ]] && source "${PROJECT_DIR}/.env"

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

# ============================================================
log_step "Step 0.5: Configuration"
# ============================================================
# Detected early: coturn (Step 6) needs SERVER_IP before Step 9 used to set it.
SERVER_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null \
  || curl -s --max-time 10 api.ipify.org 2>/dev/null \
  || hostname -I | awk '{print $1}')
DOMAIN_IP=$(echo "${SERVER_IP}" | tr '.' '-')
SUBDOMAIN_PREFIX="${SUBDOMAIN_PREFIX:-cloud}"

if [[ -n "${NC_DOMAIN:-}" ]]; then
  log_info "Reusing domain from previous run: ${NC_DOMAIN}"
else
  echo "Leave blank for a free auto-generated sslip.io domain (no DNS setup needed)."
  NC_DOMAIN_INPUT=$(ask "Custom domain (e.g. cloud.example.com), or Enter for auto")
  if [[ -n "$NC_DOMAIN_INPUT" ]]; then
    NC_DOMAIN="$NC_DOMAIN_INPUT"
  else
    NC_DOMAIN="${SUBDOMAIN_PREFIX}.${DOMAIN_IP}.sslip.io"
  fi
fi

DEFAULT_PHONE_REGION="${DEFAULT_PHONE_REGION:-$(ask "Default phone region (ISO 3166-1 alpha-2)" "IR")}"

if [[ -n "${S3_BUCKET:-}" ]]; then
  log_info "Reusing S3 object storage settings from previous run (bucket: ${S3_BUCKET})."
elif ask_yn "Use S3-compatible object storage as primary storage instead of local disk?" "n"; then
  S3_HOSTNAME=$(ask "S3 hostname (e.g. s3.example.com)")
  S3_BUCKET=$(ask "S3 bucket name")
  S3_KEY=$(ask "S3 access key")
  S3_SECRET=$(ask "S3 secret key")
  S3_PORT=$(ask "S3 port" "443")
  S3_REGION=$(ask "S3 region" "us-east-1")
  S3_USE_SSL=$(ask_yn "Use SSL?" "y" && echo "true" || echo "false")
  S3_USE_PATH_STYLE=$(ask_yn "Use path-style addressing?" "y" && echo "true" || echo "false")
else
  S3_BUCKET=""
fi

log_success "Server IP : ${SERVER_IP}"
log_success "Domain    : ${NC_DOMAIN}"

# ============================================================
log_step "Step 1: System update & base packages"
# ============================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget unzip bzip2 gnupg2 lsb-release ca-certificates \
  software-properties-common ufw openssl apt-transport-https \
  sudo cron git make
log_success "Base packages installed."

# ============================================================
log_step "Step 2: PHP 8.3 via Sury repository"
# ============================================================
# Always use Sury for a consistent PHP 8.3 across all Ubuntu versions.
if [ ! -f /usr/share/keyrings/deb.sury.org-php.gpg ]; then
  curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg \
    https://packages.sury.org/php/apt.gpg
fi
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
  https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/php.list

apt-get update -qq
apt-get install -y -qq \
  php8.3-fpm php8.3-cli \
  php8.3-pgsql php8.3-gd php8.3-curl php8.3-xml \
  php8.3-zip php8.3-mbstring php8.3-intl php8.3-bcmath \
  php8.3-gmp php8.3-bz2 php8.3-imagick \
  php8.3-redis php8.3-apcu php8.3-imap \
  libapache2-mod-php8.3 \
  php-pear php8.3-dev

PHP_INI_FPM="/etc/php/8.3/fpm/php.ini"
PHP_INI_CLI="/etc/php/8.3/cli/php.ini"

for PHP_INI in "$PHP_INI_FPM" "$PHP_INI_CLI"; do
  sed -i 's/^;*\s*memory_limit =.*/memory_limit = 1G/'              "$PHP_INI"
  sed -i 's/^;*\s*upload_max_filesize =.*/upload_max_filesize = 16G/' "$PHP_INI"
  sed -i 's/^;*\s*post_max_size =.*/post_max_size = 16G/'            "$PHP_INI"
  sed -i 's/^;*\s*max_execution_time =.*/max_execution_time = 3600/'  "$PHP_INI"
  sed -i 's/^;*\s*max_input_time =.*/max_input_time = 3600/'         "$PHP_INI"
  if ! grep -q "^date.timezone =" "$PHP_INI" 2>/dev/null; then
    sed -i "/^;*\s*date.timezone =/a date.timezone = ${DETECTED_TZ}" "$PHP_INI" 2>/dev/null \
      || echo "date.timezone = ${DETECTED_TZ}" >> "$PHP_INI"
  fi
  # output_buffering must be Off for Nextcloud compatibility
  sed -i 's/^;*\s*output_buffering =.*/output_buffering = Off/'      "$PHP_INI"
done

# OPcache + JIT -- matches AIO production settings (idempotent)
if ! grep -q "opcache.jit_buffer_size" "$PHP_INI_FPM" 2>/dev/null; then
cat >> "$PHP_INI_FPM" <<'OPCACHE'

; -- Nextcloud / AIO-grade OPcache + JIT ---------------------
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=1
opcache.jit=tracing
opcache.jit_buffer_size=128M
OPCACHE
fi

# APCu local cache (idempotent)
if ! grep -q "apc.shm_size" "$PHP_INI_FPM" 2>/dev/null; then
cat >> "$PHP_INI_FPM" <<'APCU'

; -- APCu local cache -----------------------------------------
apc.enable_cli=1
apc.shm_size=128M
APCU
fi

systemctl enable --now php8.3-fpm
systemctl reload php8.3-fpm
log_success "PHP 8.3 with OPcache+JIT and APCu configured."

# ============================================================
log_step "Step 3: Apache web server"
# ============================================================
apt-get install -y -qq apache2

a2enmod rewrite headers env dir mime ssl http2 \
        proxy proxy_http proxy_fcgi proxy_wstunnel \
        setenvif expires || true

a2enconf php8.3-fpm 2>/dev/null || true
a2dismod mpm_prefork 2>/dev/null || true
a2enmod mpm_event 2>/dev/null || true
a2dissite 000-default 2>/dev/null || true

systemctl enable --now apache2
log_success "Apache configured."

# ============================================================
log_step "Step 4: PostgreSQL (idempotent)"
# ============================================================
# If .env exists from a previous run, reuse credentials so the
# password stays in sync with what Nextcloud already has stored.
apt-get install -y -qq postgresql postgresql-contrib
systemctl enable --now postgresql
sleep 3

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  source "${PROJECT_DIR}/.env"
else
  NC_DB=nextcloud
  NC_DB_USER=nextcloud_user
  NC_DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
fi

sudo -u postgres psql <<SQLEOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${NC_DB_USER}') THEN
      CREATE USER ${NC_DB_USER} WITH PASSWORD '${NC_DB_PASS}';
   ELSE
      ALTER USER ${NC_DB_USER} WITH PASSWORD '${NC_DB_PASS}';
   END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${NC_DB} OWNER ${NC_DB_USER} ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${NC_DB}')\gexec

GRANT ALL PRIVILEGES ON DATABASE ${NC_DB} TO ${NC_DB_USER};
SQLEOF

log_success "PostgreSQL database '${NC_DB}' and user '${NC_DB_USER}' synchronized."

# ============================================================
log_step "Step 5: Redis (unix socket with TCP fallback)"
# ============================================================
apt-get install -y -qq redis-server

REDIS_CONF="/etc/redis/redis.conf"
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/'           "$REDIS_CONF"
sed -i 's/^# maxmemory-policy.*/maxmemory-policy allkeys-lru/' "$REDIS_CONF"
sed -i 's|^# unixsocket .*|unixsocket /run/redis/redis.sock|' "$REDIS_CONF"
sed -i 's/^# unixsocketperm.*/unixsocketperm 770/'         "$REDIS_CONF"

systemctl enable --now redis-server
sleep 2

usermod -aG redis www-data 2>/dev/null || true
chown redis:redis /run/redis/redis.sock 2>/dev/null || true
chmod 770 /run/redis/redis.sock 2>/dev/null || true

# Verify socket is reachable; fall back to TCP if not.
REDIS_OK=false
for i in {1..5}; do
  if redis-cli -s /run/redis/redis.sock ping 2>/dev/null | grep -q PONG; then
    REDIS_OK=true
    break
  fi
  sleep 1
done

if $REDIS_OK; then
  log_success "Redis reachable via unix socket."
  REDIS_HOST="/run/redis/redis.sock"
  REDIS_PORT=0
else
  log_warn "Redis socket not reachable -- falling back to TCP 127.0.0.1:6379"
  sed -i 's|^unixsocket .*|#unixsocket /run/redis/redis.sock|' "$REDIS_CONF"
  sed -i 's/^unixsocketperm.*/#unixsocketperm 770/'         "$REDIS_CONF"
  systemctl restart redis-server
  sleep 2
  REDIS_HOST="127.0.0.1"
  REDIS_PORT=6379
fi

log_success "Redis configured."

# ============================================================
log_step "Step 6: coturn (TURN server for Talk)"
# ============================================================
apt-get install -y -qq coturn

TURN_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

cat > /etc/turnserver.conf <<TURNEOF
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=0.0.0.0
external-ip=${SERVER_IP}
fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=nextcloud
total-quota=100
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
log-file=/var/log/turnserver.log
no-stdout-log
TURNEOF

sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' \
  /etc/default/coturn 2>/dev/null || \
  echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn

systemctl enable --now coturn
log_success "coturn TURN server configured."

# ============================================================
log_step "Step 7: BorgBackup"
# ============================================================
apt-get install -y -qq borgbackup
log_success "BorgBackup installed."

# ============================================================
log_step "Step 8: Install Docker & Docker Compose"
# ============================================================
# Docker is required for the heavy services: Imaginary, Elasticsearch,
# Whiteboard, Talk Recording, Janus, and Docker Socket Proxy.
if ! command -v docker &>/dev/null; then
  log_info "Installing Docker..."
  # Install Docker from official APT repository (no curl|sh)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  log_success "Docker installed."
else
  log_info "Docker already installed: $(docker --version)"
fi

# Ensure docker compose v2 plugin is available
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi
log_success "Docker Compose available: $(docker compose version --short)"

# Add www-data to docker group for AppAPI
usermod -aG docker www-data 2>/dev/null || true

# ============================================================
log_step "Step 9: Server IP & domain"
# ============================================================
# Detected during Step 0.5 (coturn in Step 6 needs SERVER_IP earlier).
log_success "Server IP : ${SERVER_IP}"
log_success "Domain    : ${NC_DOMAIN}"

# ============================================================
log_step "Step 10: Download & verify Nextcloud"
# ============================================================
mkdir -p "${NCWWW_DIR}" "${NCDATA_DIR}"

log_info "Downloading latest Nextcloud..."
wget -q --show-progress \
  -O /tmp/nextcloud.tar.bz2 \
  "https://download.nextcloud.com/server/releases/latest.tar.bz2"
wget -q \
  -O /tmp/nextcloud.tar.bz2.sha256 \
  "https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256"

log_info "Verifying checksum..."
# Extract only the first hash (file contains hashes for .tar.bz2 and .metadata).
EXPECTED_HASH=$(awk 'NR==1{print $1}' /tmp/nextcloud.tar.bz2.sha256)
ACTUAL_HASH=$(sha256sum /tmp/nextcloud.tar.bz2 | awk '{print $1}')
if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
  log_error "Checksum mismatch -- download may be corrupt."
  exit 1
fi
log_success "Checksum OK."

tar -xjf /tmp/nextcloud.tar.bz2 -C /tmp/
cp -r /tmp/nextcloud/. "${NCWWW_DIR}/"
rm -rf /tmp/nextcloud /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.sha256

chown -R www-data:www-data "${NCWWW_DIR}" "${NCDATA_DIR}"
chmod -R 755 "${NCWWW_DIR}"
chmod -R 750 "${NCDATA_DIR}"
log_success "Nextcloud deployed to ${NCWWW_DIR}."

# ============================================================
log_step "Step 11: Apache virtual host (HTTP -- pre-SSL)"
# ============================================================
cat > /etc/apache2/sites-available/nextcloud.conf <<APACHEEOF
<VirtualHost *:80>
    ServerName ${NC_DOMAIN}
    DocumentRoot ${NCWWW_DIR}

    ProxyPreserveHost On

    # Redirect away from the "Recommended apps" page that appears after first
    # setup. This page has a known authentication bug in Nextcloud 32+. All
    # apps are installed automatically by post-setup.sh, so this page is
    # unnecessary. The redirect sends the user straight to the file manager.
    RedirectMatch 302 ^/index\.php/core/apps/recommended$ /apps/files/
    RedirectMatch 302 ^/core/apps/recommended$           /apps/files/

    # notify_push client push
    ProxyPass        /push/ws  ws://127.0.0.1:7867/push/ws
    ProxyPass        /push/    http://127.0.0.1:7867/push/
    ProxyPassReverse /push/    http://127.0.0.1:7867/push/

    # High-performance backend (Talk signaling).
    # The /standalone-signaling prefix is stripped before forwarding so the
    # signaling server receives requests at its own root (e.g. /api/v1/welcome).
    ProxyPass     /standalone-signaling/spreed    ws://127.0.0.1:8081/spreed 
    ProxyPassReverse    /standalone-signaling/spreed    ws://127.0.0.1:8081/spreed
    ProxyPass    /standalone-signaling/     http://127.0.0.1:8081/ 
    ProxyPassReverse    /standalone-signaling/   http://127.0.0.1:8081/

    # Euro-Office Document Server (online office editing).
    # All traffic goes via ws:// — mod_proxy_wstunnel handles both WS and HTTP.
    ProxyPass        /eurooffice/    ws://127.0.0.1:9980/
    ProxyPassReverse /eurooffice/    http://127.0.0.1:9980/
    # DS generates some asset URLs at root level (without /eurooffice/ prefix).
    ProxyPass        /sdkjs/         ws://127.0.0.1:9980/sdkjs/
    ProxyPassReverse /sdkjs/         http://127.0.0.1:9980/sdkjs/
    ProxyPass        /web-apps/      ws://127.0.0.1:9980/web-apps/
    ProxyPassReverse /web-apps/      http://127.0.0.1:9980/web-apps/
    ProxyPass        /sdkjs-plugins/ ws://127.0.0.1:9980/sdkjs-plugins/
    ProxyPassReverse /sdkjs-plugins/ http://127.0.0.1:9980/sdkjs-plugins/
    ProxyPass        /fonts/         ws://127.0.0.1:9980/fonts/
    ProxyPassReverse /fonts/         http://127.0.0.1:9980/fonts/
    ProxyPass        /dictionaries/  ws://127.0.0.1:9980/dictionaries/
    ProxyPassReverse /dictionaries/  http://127.0.0.1:9980/dictionaries/
    ProxyPass        /cache/files/   ws://127.0.0.1:9980/cache/files/
    ProxyPassReverse /cache/files/   http://127.0.0.1:9980/cache/files/

    <Directory ${NCWWW_DIR}>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        SetEnv HOME ${NCWWW_DIR}
        SetEnv HTTP_HOME ${NCWWW_DIR}
    </Directory>

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Permitted-Cross-Domain-Policies "none"
        Header always set X-Robots-Tag "noindex, nofollow"
        Header always set Referrer-Policy "no-referrer"
        Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' wss: https:; media-src 'self'; frame-src 'self' https:; child-src 'self'; worker-src 'self' blob:"
    </IfModule>

    # Tell Euro-Office Document Server the external protocol is HTTPS
    # (needed so WOPI discovery returns https:// URLs)
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port  "443"
    RequestHeader set X-Forwarded-Prefix "/eurooffice"

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/xml
        AddOutputFilterByType DEFLATE text/css application/javascript
        AddOutputFilterByType DEFLATE application/json
    </IfModule>

    ErrorLog  \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
APACHEEOF

a2ensite nextcloud
if apache2ctl configtest 2>&1; then
  systemctl reload apache2
  log_success "Apache virtual host configured."
else
  log_warn "Apache configtest failed -- check config manually."
fi

# ============================================================
log_step "Step 12: UFW firewall"
# ============================================================
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp   2>/dev/null || true
  ufw allow 80/tcp   2>/dev/null || true
  ufw allow 443/tcp  2>/dev/null || true
  ufw allow 3478/tcp 2>/dev/null || true
  ufw allow 3478/udp 2>/dev/null || true
  ufw allow 5349/tcp 2>/dev/null || true
  # Internal services (HPB, HaRP) are bound to 127.0.0.1 — no public access needed
  ufw --force enable
  ufw reload
  log_success "UFW: ports 22, 80, 443, 3478, 5349 open (8081/HPB stays loopback-only, reached via Apache proxy)."
else
  log_warn "UFW not found -- skipping firewall config."
fi

# ============================================================
log_step "Step 13: Let's Encrypt SSL certificate"
# ============================================================
apt-get install -y -qq certbot python3-certbot-apache

log_info "Requesting certificate for: ${NC_DOMAIN}"
if certbot --apache \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  -d "${NC_DOMAIN}" 2>> "${LOG_DIR}/app-install.log"; then
  log_success "SSL certificate obtained."
else
  log_warn "Certbot failed -- generating self-signed certificate."
  mkdir -p /etc/ssl/nextcloud
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/nextcloud/privkey.pem \
    -out /etc/ssl/nextcloud/cert.pem \
    -subj "/CN=${NC_DOMAIN}" 2>/dev/null
  # Enable SSL vhost with self-signed cert
  a2enmod ssl
  cat > /etc/apache2/sites-available/nextcloud-le-ssl.conf <<SSLEOF
<IfModule mod_ssl.c>
<VirtualHost *:443>
  ServerName ${NC_DOMAIN}
  DocumentRoot ${NCWWW_DIR}
  SSLEngine on
  SSLCertificateFile /etc/ssl/nextcloud/cert.pem
  SSLCertificateKeyFile /etc/ssl/nextcloud/privkey.pem
  <Directory ${NCWWW_DIR}>
      Options +FollowSymlinks
      AllowOverride All
      Require all granted
      SetEnv HOME ${NCWWW_DIR}
      SetEnv HTTP_HOME ${NCWWW_DIR}
  </Directory>
</VirtualHost>
</IfModule>
SSLEOF
  a2ensite nextcloud-le-ssl
  log_warn "Using self-signed certificate. Run certbot manually later."
fi

# Certbot creates a separate SSL vhost (nextcloud-le-ssl.conf).
# Inject the same proxy rules into it so HPB and notify_push work over HTTPS.
SSL_CONF="/etc/apache2/sites-available/nextcloud-le-ssl.conf"
if [[ -f "$SSL_CONF" ]]; then
  if ! grep -q "standalone-signaling" "$SSL_CONF"; then
    cp "$SSL_CONF" "${SSL_CONF}.bak"
    python3 - <<PYEOF_SSL
import os, tempfile
path = '${SSL_CONF}'
with open(path) as f:
    c = f.read()
inject = """    ProxyPreserveHost On
    RedirectMatch 302 ^/index\\.php/core/apps/recommended$ /apps/files/
    RedirectMatch 302 ^/core/apps/recommended$           /apps/files/
    ProxyPass        /push/ws  ws://127.0.0.1:7867/push/ws
    ProxyPass        /push/    http://127.0.0.1:7867/push/
    ProxyPassReverse /push/    http://127.0.0.1:7867/push/
    ProxyPass     /standalone-signaling/spreed    ws://127.0.0.1:8081/spreed
    ProxyPassReverse    /standalone-signaling/spreed    ws://127.0.0.1:8081/spreed
    ProxyPass    /standalone-signaling/     http://127.0.0.1:8081/
    ProxyPassReverse    /standalone-signaling/   http://127.0.0.1:8081/
    ProxyPass        /eurooffice/    ws://127.0.0.1:9980/
    ProxyPassReverse /eurooffice/    http://127.0.0.1:9980/
    # DS generates some asset URLs at root level (without /eurooffice/ prefix).
    ProxyPass        /sdkjs/         ws://127.0.0.1:9980/sdkjs/
    ProxyPassReverse /sdkjs/         http://127.0.0.1:9980/sdkjs/
    ProxyPass        /web-apps/      ws://127.0.0.1:9980/web-apps/
    ProxyPassReverse /web-apps/      http://127.0.0.1:9980/web-apps/
    ProxyPass        /sdkjs-plugins/ ws://127.0.0.1:9980/sdkjs-plugins/
    ProxyPassReverse /sdkjs-plugins/ http://127.0.0.1:9980/sdkjs-plugins/
    ProxyPass        /fonts/         ws://127.0.0.1:9980/fonts/
    ProxyPassReverse /fonts/         http://127.0.0.1:9980/fonts/
    ProxyPass        /dictionaries/  ws://127.0.0.1:9980/dictionaries/
    ProxyPassReverse /dictionaries/  http://127.0.0.1:9980/dictionaries/
    ProxyPass        /cache/files/   ws://127.0.0.1:9980/cache/files/
    ProxyPassReverse /cache/files/   http://127.0.0.1:9980/cache/files/
    # Tell Euro-Office DS the external protocol is HTTPS (WOPI fix)
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port  "443"
    RequestHeader set X-Forwarded-Prefix "/eurooffice"
"""
c = c.replace('</VirtualHost>', inject + '</VirtualHost>', 1)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    f.write(c)
os.rename(tmp, path)
PYEOF_SSL
    log_success "Proxy rules injected into SSL vhost."
  else
    log_info "SSL vhost already has proxy rules."
  fi
fi

a2enmod http2 2>/dev/null || true
systemctl reload apache2

# ============================================================
log_step "Step 14: Generate credentials"
# ============================================================
# Reuse from a previous run if present -- regenerating would desync
# from the admin password already stored in the Nextcloud database.
NC_ADMIN_USER="${NC_ADMIN_USER:-ncadmin-$(openssl rand -hex 4)}"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#%^&*' | head -c 24)}"

cat > "${PROJECT_DIR}/.env" <<ENVEOF
# Nextcloud Install Secrets -- chmod 600
NC_DOMAIN=${NC_DOMAIN}
SERVER_IP=${SERVER_IP}
NC_ADMIN_USER=${NC_ADMIN_USER}
NC_ADMIN_PASS=${NC_ADMIN_PASS}
NC_DB=${NC_DB}
NC_DB_USER=${NC_DB_USER}
NC_DB_PASS=${NC_DB_PASS}
TURN_SECRET=${TURN_SECRET}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
DETECTED_TZ=${DETECTED_TZ}
DEFAULT_PHONE_REGION=${DEFAULT_PHONE_REGION}
S3_HOSTNAME=${S3_HOSTNAME:-}
S3_BUCKET=${S3_BUCKET:-}
S3_KEY=${S3_KEY:-}
S3_SECRET=${S3_SECRET:-}
S3_PORT=${S3_PORT:-}
S3_REGION=${S3_REGION:-}
S3_USE_SSL=${S3_USE_SSL:-}
S3_USE_PATH_STYLE=${S3_USE_PATH_STYLE:-}
ENVEOF
chmod 600 "${PROJECT_DIR}/.env"
log_success "Admin credentials generated."
log_info "Username: ${NC_ADMIN_USER}"

# -- Docker service secrets (generated upfront for one-click install) -
DOCKER_DIR="/opt/nextcloud-docker"
mkdir -p "${DOCKER_DIR}"

SOCK_PROXY_PASS="${SOCK_PROXY_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
WHITEBOARD_SECRET="${WHITEBOARD_SECRET:-$(openssl rand -hex 32)}"
RECORDING_SECRET="${RECORDING_SECRET:-$(openssl rand -hex 32)}"
EUROOFFICE_JWT_SECRET="${EUROOFFICE_JWT_SECRET:-$(openssl rand -hex 32)}"
INTERNAL_SECRET="${INTERNAL_SECRET:-$(openssl rand -hex 32)}"
HARP_SHARED_KEY="${HARP_SHARED_KEY:-$(openssl rand -hex 32)}"
BORG_PASSPHRASE="${BORG_PASSPHRASE:-$(openssl rand -hex 32)}"
SIGNALING_SECRET="${SIGNALING_SECRET:-$(openssl rand -hex 32)}"

cat >> "${PROJECT_DIR}/.env" <<DOCKERSECEOF
DOCKER_DIR=${DOCKER_DIR}
SOCK_PROXY_PASS=${SOCK_PROXY_PASS}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
WHITEBOARD_SECRET=${WHITEBOARD_SECRET}
RECORDING_SECRET=${RECORDING_SECRET}
EUROOFFICE_JWT_SECRET=${EUROOFFICE_JWT_SECRET}
INTERNAL_SECRET=${INTERNAL_SECRET}
HARP_SHARED_KEY=${HARP_SHARED_KEY}
BORG_PASSPHRASE=${BORG_PASSPHRASE}
SIGNALING_SECRET=${SIGNALING_SECRET}
DOCKERSECEOF
chmod 600 "${PROJECT_DIR}/.env"
log_success "Docker service secrets generated."

# ============================================================
log_step "Step 15: Start Docker services (must run before Nextcloud config)"
# ============================================================
# Docker services must be up before Nextcloud tries to detect/configure them.

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "${RAM_MB}" -lt 1800 ]; then
  log_warn "Server has ${RAM_MB}MB RAM. Elasticsearch recommends 2GB+. Adjusting heap..."
  ES_HEAP="256m"
else
  ES_HEAP="512m"
fi

# Install Farsi/Arabic fonts for Euro-Office Document Server
log_info "Installing Farsi/Arabic fonts for Euro-Office..."
mkdir -p "${DOCKER_DIR}/shared-fonts/fonts"
apt-get install -y -qq fonts-noto-core fonts-noto-extra fonts-freefont-ttf >/dev/null 2>&1 || true
cp -r /usr/share/fonts/* "${DOCKER_DIR}/shared-fonts/fonts/" 2>/dev/null || true

# Install Vazirmatn (Persian web font)
log_info "Installing Vazirmatn font..."
VAZIR_VER=$(curl -sL 'https://api.github.com/repos/rastikerdar/vazirmatn/releases/latest' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name","v33.003"))' 2>/dev/null || echo "v33.003")
curl -sL -o /tmp/vazirmatn.zip "https://github.com/rastikerdar/vazirmatn/releases/download/${VAZIR_VER}/vazirmatn-${VAZIR_VER}.zip" 2>/dev/null || true
if [ -s /tmp/vazirmatn.zip ]; then
  mkdir -p /usr/share/fonts/truetype/vazirmatn
  unzip -oq /tmp/vazirmatn.zip -d /usr/share/fonts/truetype/vazirmatn/ 2>/dev/null || true
  cp -r /usr/share/fonts/truetype/vazirmatn "${DOCKER_DIR}/shared-fonts/fonts/truetype/" 2>/dev/null || true
  fc-cache -f 2>/dev/null || true
  rm -f /tmp/vazirmatn.zip
  log_success "Vazirmatn font installed."
fi

log_success "Farsi/Arabic fonts installed."

# Patched start.sh for talk-recording: uses https:// for backend (REST API)
# but wss:// for signaling (WebSocket). The original start.sh uses a single
# HPB_PROTOCOL for both, which breaks one of them.
cat > "${DOCKER_DIR}/recording-start.sh" <<'RECEOF'
#!/bin/bash
if [ -z "$NC_DOMAIN" ]; then
    echo "You need to provide the NC_DOMAIN."
    exit 1
elif [ -z "$RECORDING_SECRET" ]; then
    echo "You need to provide the RECORDING_SECRET."
    exit 1
elif [ -z "$INTERNAL_SECRET" ]; then
    echo "You need to provide the INTERNAL_SECRET."
    exit 1
fi

if [ -z "$HPB_DOMAIN" ]; then
    export HPB_DOMAIN="$NC_DOMAIN"
fi

rm -fr /tmp/{*,.*}

# Backend uses https:// (REST API), signaling uses wss:// (WebSocket)
BACKEND_URL="${HPB_PROTOCOL:-https}://${NC_DOMAIN}"
SIGNALING_URL="wss://${HPB_DOMAIN}${HPB_PATH}"

cat << RECORDING_CONF > "/conf/recording.conf"
[logs]
level = 30

[http]
listen = 0.0.0.0:1234

[backend]
allowall = ${ALLOW_ALL}
secret = ${RECORDING_SECRET}
backends = backend-1
skipverify = ${SKIP_VERIFY}
maxmessagesize = 1024
videowidth = 1920
videoheight = 1080
directory = /tmp

[backend-1]
url = ${BACKEND_URL}
secret = ${RECORDING_SECRET}
skipverify = ${SKIP_VERIFY}

[signaling]
signalings = signaling-1

[signaling-1]
url = ${SIGNALING_URL}
internalsecret = ${INTERNAL_SECRET}

[ffmpeg]
extensionaudio = .ogg
extensionvideo = .webm

[recording]
browser = firefox
RECORDING_CONF

exec "$@"
RECEOF
chmod +x "${DOCKER_DIR}/recording-start.sh"

cat > "${DOCKER_DIR}/docker-compose.yml" <<COMPOSEEOF
# Nextcloud Full -- Docker services
# Start: docker compose -f ${DOCKER_DIR}/docker-compose.yml up -d
# Stop:  docker compose -f ${DOCKER_DIR}/docker-compose.yml down

services:

  imaginary:
    image: nextcloud/aio-imaginary:latest
    container_name: nc-imaginary
    restart: unless-stopped
    environment:
      - PORT=9000
    command: -concurrency 20 -enable-url-source
    ports:
      - "127.0.0.1:9000:9000"
    cap_add:
      - SYS_NICE

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
    container_name: nc-elasticsearch
    restart: unless-stopped
    environment:
      - discovery.type=single-node
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - ES_JAVA_OPTS=-Xms${ES_HEAP} -Xmx${ES_HEAP}
      - bootstrap.memory_lock=true
    ports:
      - "127.0.0.1:9200:9200"
    volumes:
      - nc-elasticsearch-data:/usr/share/elasticsearch/data
    ulimits:
      memlock:
        soft: 65536
        hard: 65536
      nofile:
        soft: 65536
        hard: 65536

  whiteboard:
    image: ghcr.io/nextcloud-releases/whiteboard:release
    container_name: nc-whiteboard
    restart: unless-stopped
    environment:
      - NEXTCLOUD_URL=https://${NC_DOMAIN}
      - JWT_SECRET_KEY=${WHITEBOARD_SECRET}
      - STORAGE_STRATEGY=nextcloud
    ports:
      - "127.0.0.1:3002:3002"
    healthcheck:
      test: ["CMD-SHELL", "node -e 'require(\"net\").createConnection(3002, \"localhost\").on(\"connect\", () => process.exit(0)).on(\"error\", () => process.exit(1))'"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  janus:
    image: canyan/janus-gateway:latest
    container_name: nc-janus
    restart: unless-stopped
    network_mode: host
    environment:
      - JANUS_RTP_PORT_RANGE=20000-40000

  talk-recording:
    image: nextcloud/aio-talk-recording:latest
    container_name: nc-talk-recording
    restart: unless-stopped
    network_mode: host
    depends_on:
      - janus
    environment:
      - INTERNAL_SECRET=${INTERNAL_SECRET}
      - NC_DOMAIN=${NC_DOMAIN}
      - RECORDING_SECRET=${RECORDING_SECRET}
      - SIGNALING_SECRET=${SIGNALING_SECRET}
      - HPB_PROTOCOL=https
      - HPB_PATH=/standalone-signaling/
      - JANUS_URL=ws://127.0.0.1:8188
    volumes:
      - nc-recording-data:/data
      - ${DOCKER_DIR}/recording-start.sh:/start.sh:ro

  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: nc-docker-socket-proxy
    restart: unless-stopped
    environment:
      - DOCKER_API_VERSION=1.45
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - POST=1
      - BUILD=0
      - COMMIT=0
      - CONFIGS=0
      - EXEC=1
      - SERVICES=0
      - SWARM=0
      - TASKS=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "127.0.0.1:2375:2375"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: nc-watchtower
    restart: unless-stopped
    environment:
      - DOCKER_API_VERSION=1.45
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
      - WATCHTOWER_ROLLING_RESTART=true
      - TZ=${DETECTED_TZ}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  # -- Euro-Office Document Server: online office editing -------
  euro-office:
    image: ghcr.io/euro-office/documentserver:latest
    container_name: nc-euro-office
    restart: unless-stopped
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=${EUROOFFICE_JWT_SECRET}
      - JWT_HEADER=AuthorizationJwt
      - WOPI_ENABLED=true
      - ALLOW_PRIVATE_IP_ADDRESS=true
    ports:
      - "127.0.0.1:9980:80"
    volumes:
      - nc-eurooffice-data:/var/lib/euro-office
      - nc-eurooffice-config:/etc/euro-office
      - nc-eurooffice-logs:/var/log/euro-office
      - ${DOCKER_DIR}/shared-fonts/fonts:/usr/share/fonts:ro
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/healthcheck"]
      interval: 30s
      retries: 5
      start_period: 60s
      timeout: 10s

  # -- HaRP: AppAPI ExApps proxy (replaces Docker Socket Proxy) -----
  harp:
    image: ghcr.io/nextcloud/nextcloud-appapi-harp:release
    container_name: appapi-harp
    hostname: appapi-harp
    restart: unless-stopped
    network_mode: host
    environment:
      - HP_SHARED_KEY=${HARP_SHARED_KEY}
      - NC_INSTANCE_URL=https://${NC_DOMAIN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock  # HaRP needs :rw to manage ExApps
      - harp-certs:/certs

volumes:
  nc-elasticsearch-data:
  nc-recording-data:
  nc-eurooffice-data:
  nc-eurooffice-config:
  nc-eurooffice-logs:
  harp-certs:
COMPOSEEOF

log_info "Configuring kernel for Elasticsearch..."
sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null \
  || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

log_info "Starting Docker services..."
if ! docker compose -f "${DOCKER_DIR}/docker-compose.yml" pull --quiet; then
  log_warn "Some images failed to pull -- continuing with available images."
fi
docker compose -f "${DOCKER_DIR}/docker-compose.yml" up -d || {
  log_error "Failed to start Docker services."
  log_error "Check: docker compose -f ${DOCKER_DIR}/docker-compose.yml logs"
  log_error "You may need to fix the issue and re-run the script."
  exit 1
}

log_info "Waiting for Docker services to be ready..."
for i in $(seq 1 60); do
  RUNNING=$(docker compose -f "${DOCKER_DIR}/docker-compose.yml" ps --status running --quiet 2>/dev/null | wc -l | tr -d '[:space:]')
  HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' nc-euro-office nc-whiteboard nc-talk-recording appapi-harp 2>/dev/null | grep -c "healthy" | tr -d '[:space:]' || true)
  HEALTHY=${HEALTHY:-0}
  if [ "${RUNNING}" -ge 9 ] && [ "${HEALTHY}" -ge 3 ]; then
    break
  fi
  sleep 5
done

RUNNING=$(docker compose -f "${DOCKER_DIR}/docker-compose.yml" ps --status running --quiet 2>/dev/null | wc -l | tr -d '[:space:]')
HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' nc-euro-office nc-whiteboard nc-talk-recording appapi-harp 2>/dev/null | grep -c "healthy" | tr -d '[:space:]' || true)
HEALTHY=${HEALTHY:-0}
log_success "Docker services started: ${RUNNING}/9 containers running, ${HEALTHY}/4 healthy."
if [ "${HEALTHY}" -lt 3 ]; then
  log_warn "Only ${HEALTHY}/4 services healthy. Some may need manual attention."
fi

# ============================================================
log_step "Step 16: Install Nextcloud via occ"
# ============================================================
OCC="sudo -u www-data php ${NCWWW_DIR}/occ"

log_info "Running Nextcloud CLI install..."
if $OCC status 2>/dev/null | grep -q "installed: true"; then
  log_warn "Nextcloud already installed -- skipping."
else
  if [[ -n "${S3_BUCKET:-}" ]]; then
    # maintenance:install merges dbtype/instanceid/passwordsalt/secret into
    # this file rather than overwriting it, so pre-seeding just objectstore
    # here is enough -- and safer than letting the S3 keys ever touch argv.
    mkdir -p "${NCWWW_DIR}/config"
    cat > "${NCWWW_DIR}/config/config.php" <<CONFIGEOF
<?php
\$CONFIG = [
  'objectstore' => [
    'class'     => '\\OC\\Files\\ObjectStore\\S3',
    'arguments' => [
      'bucket'         => '${S3_BUCKET}',
      'key'            => '${S3_KEY}',
      'secret'         => '${S3_SECRET}',
      'hostname'       => '${S3_HOSTNAME}',
      'port'           => ${S3_PORT},
      'use_ssl'        => ${S3_USE_SSL},
      'use_path_style' => ${S3_USE_PATH_STYLE},
      'region'         => '${S3_REGION}',
      'autocreate'     => false,
    ],
  ],
];
CONFIGEOF
    chown www-data:www-data "${NCWWW_DIR}/config/config.php"
    chmod 640 "${NCWWW_DIR}/config/config.php"
    log_success "S3 primary storage pre-configured (bucket: ${S3_BUCKET})."
  fi
  $OCC maintenance:install \
    --database      "pgsql" \
    --database-host "127.0.0.1" \
    --database-name "${NC_DB}" \
    --database-user "${NC_DB_USER}" \
    --database-pass "${NC_DB_PASS}" \
    --admin-user    "${NC_ADMIN_USER}" \
    --admin-pass    "${NC_ADMIN_PASS}" \
    --data-dir      "${NCDATA_DIR}" 2>&1
  log_success "Nextcloud core installed."
fi

# -- Trusted domain & URLs ------------------------------------
$OCC config:system:set trusted_domains 0 --value="${NC_DOMAIN}"           2>/dev/null || true
$OCC config:system:set overwrite.cli.url  --value="https://${NC_DOMAIN}"  2>/dev/null || true
$OCC config:system:set overwriteprotocol  --value="https"                 2>/dev/null || true
$OCC config:system:set overwritehost      --value="${NC_DOMAIN}"          2>/dev/null || true
$OCC config:system:set trusted_proxies 0  --value="127.0.0.1"            2>/dev/null || true
$OCC config:system:set trusted_proxies 1  --value="${SERVER_IP}"          2>/dev/null || true
$OCC config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR" 2>/dev/null || true

# -- Redis ----------------------------------------------------
$OCC config:system:set memcache.local       --value='\OC\Memcache\APCu'  2>/dev/null || true
$OCC config:system:set memcache.locking     --value='\OC\Memcache\Redis' 2>/dev/null || true
$OCC config:system:set memcache.distributed --value='\OC\Memcache\Redis' 2>/dev/null || true
$OCC config:system:set redis host           --value="${REDIS_HOST}"          2>/dev/null || true
$OCC config:system:set redis port           --value=${REDIS_PORT} --type=integer 2>/dev/null || true

# -- General system settings ----------------------------------
$OCC config:system:set logtimezone           --value="${DETECTED_TZ}"    2>/dev/null || true
$OCC config:system:set default_phone_region  --value="${DEFAULT_PHONE_REGION}" 2>/dev/null || true
$OCC config:system:set skeletondirectory     --value=""                  2>/dev/null || true
$OCC config:system:set trashbin_retention_obligation --value="auto, 30"  2>/dev/null || true
$OCC config:system:set versions_retention_obligation --value="auto, 30"  2>/dev/null || true
$OCC config:system:set htaccess.RewriteBase  --value="/"                 2>/dev/null || true
$OCC maintenance:update:htaccess                                          2>/dev/null || true
$OCC config:system:set appconfig files max_chunk_size --value="0"        2>/dev/null || true
$OCC config:system:set maintenance_window_start --type=integer --value=2  2>/dev/null || true
$OCC config:system:set server_id --value="$(hostname)"                   2>/dev/null || true

# -- TURN server ----------------------------------------------
$OCC config:app:set spreed stun_servers \
  --value="[{\"server\":\"stun.l.google.com:19302\",\"schemes\":\"stun:\"}]" 2>/dev/null || true
$OCC config:app:set spreed turn_servers --value="[]" 2>/dev/null || true
$OCC config:app:set spreed turn_secret --value="${TURN_SECRET}" 2>/dev/null || true

# -- Calendar & notifications ---------------------------------
$OCC config:app:set dav sendEventRemindersMode --value=occ               2>/dev/null || true
$OCC config:app:set dav sendEventRemindersPush --value=1                 2>/dev/null || true
$OCC config:app:set admin_notifications push_to_talk --value=1           2>/dev/null || true
$OCC config:app:set spreed signaling_dev --value=0                       2>/dev/null || true

log_success "System configs applied."

# -- Install apps ---------------------------------------------
install_app() {
  local APP_ID="$1"
  local DISPLAY_NAME="$2"
  log_info "Installing: ${DISPLAY_NAME}"
  if $OCC app:install "${APP_ID}" --no-interaction >> "${LOG_DIR}/app-install.log" 2>&1; then
    log_success "  [ok] ${DISPLAY_NAME}"
  else
    if $OCC app:enable "${APP_ID}" >> "${LOG_DIR}/app-install.log" 2>&1; then
      log_success "  [ok] ${DISPLAY_NAME} enabled."
    else
      log_warn "  [!!] ${DISPLAY_NAME} could not be installed."
    fi
  fi
}

install_app "spreed"               "Nextcloud Talk"
install_app "calendar"             "Nextcloud Calendar"
install_app "contacts"             "Nextcloud Contacts"
install_app "mail"                 "Nextcloud Mail"
install_app "eurooffice" "Nextcloud Office (Euro-Office)"
install_app "assistant"            "Nextcloud Assistant"
install_app "flow_notifications"   "Nextcloud Flow"
install_app "deck"                 "Nextcloud Deck"
install_app "notify_push"          "Push Notification"
install_app "twofactor_totp"       "Two-Factor TOTP"

$OCC app:enable files_external                   >> "${LOG_DIR}/app-install.log" 2>&1 || true
$OCC app:enable twofactor_nextcloud_notification >> "${LOG_DIR}/app-install.log" 2>&1 || true
$OCC app:disable firstrunwizard                  >> "${LOG_DIR}/app-install.log" 2>&1 || true

log_success "All apps installed."

# -- notify_push daemon ---------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        PUSH_BINARY="${NCWWW_DIR}/apps/notify_push/bin/x86_64/notify_push" ;;
  aarch64|arm64) PUSH_BINARY="${NCWWW_DIR}/apps/notify_push/bin/aarch64/notify_push" ;;
  *)             PUSH_BINARY="" ;;
esac

if [[ -n "$PUSH_BINARY" && -f "$PUSH_BINARY" ]]; then
  chmod +x "$PUSH_BINARY"
  cat > /etc/systemd/system/notify_push.service <<PUSHEOF
[Unit]
Description=Nextcloud Client Push (notify_push)
After=network.target postgresql.service redis-server.service apache2.service

[Service]
Environment=PORT=7867
Environment=NEXTCLOUD_URL=https://${NC_DOMAIN}
ExecStart=${PUSH_BINARY} ${NCWWW_DIR}/config/config.php
User=www-data
Group=www-data
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
PUSHEOF

  systemctl daemon-reload
  systemctl enable --now notify_push
  sleep 5
  if $OCC notify_push:setup "https://${NC_DOMAIN}/push" >> "${LOG_DIR}/notify_push.log" 2>&1; then
    log_success "notify_push configured."
    systemctl restart notify_push
    sleep 3
    $OCC notify_push:self-test >> "${LOG_DIR}/notify_push.log" 2>&1 && \
      log_success "notify_push self-test passed." || \
      log_warn "notify_push self-test had issues."
  else
    log_warn "notify_push setup failed -- run manually after install."
  fi
fi

# -- Configure Docker services in Nextcloud -------------------
# Imaginary
log_info "Waiting for Imaginary..."
for i in $(seq 1 12); do
  if curl -sf http://127.0.0.1:9000/health 2>/dev/null | grep -q "uptime\|OK"; then break; fi
  sleep 5
done
if curl -s http://127.0.0.1:9000/health 2>/dev/null | grep -q "uptime\|OK"; then
  $OCC config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary" 2>/dev/null || true
  $OCC config:system:set preview_imaginary_url    --value="http://127.0.0.1:9000"       2>/dev/null || true
  $OCC config:system:set preview_max_x --value="2048" --type=integer                   2>/dev/null || true
  $OCC config:system:set preview_max_y --value="2048" --type=integer                   2>/dev/null || true
  log_success "Imaginary configured for previews."
fi

# Elasticsearch
log_info "Waiting for Elasticsearch..."
for i in $(seq 1 30); do
  if curl -sf -u "elastic:${ELASTIC_PASSWORD}" http://127.0.0.1:9200/_cluster/health 2>/dev/null | grep -q "green\|yellow"; then break; fi
  sleep 5
done
if curl -s -u "elastic:${ELASTIC_PASSWORD}" http://127.0.0.1:9200/_cluster/health 2>/dev/null | grep -q "green\|yellow"; then
  $OCC app:install fulltextsearch               >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable fulltextsearch 2>/dev/null || true
  $OCC app:install fulltextsearch_elasticsearch >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable fulltextsearch_elasticsearch 2>/dev/null || true
  $OCC app:install files_fulltextsearch         >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable files_fulltextsearch 2>/dev/null || true
  echo '{"search_platform":"OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"}' | \
    $OCC fulltextsearch:configure \
    >> "${LOG_DIR}/app-install.log" 2>&1 || true
  $OCC config:app:set fulltextsearch_elasticsearch elastic_host \
    --value="http://elastic:${ELASTIC_PASSWORD}@127.0.0.1:9200" \
    >> "${LOG_DIR}/app-install.log" 2>&1 || true
  $OCC config:app:set fulltextsearch_elasticsearch elastic_index \
    --value="nextcloud" \
    >> "${LOG_DIR}/app-install.log" 2>&1 || true
  $OCC config:app:set fulltextsearch_elasticsearch elastic_user \
    --value="elastic" \
    >> "${LOG_DIR}/app-install.log" 2>&1 || true
  $OCC config:app:set fulltextsearch_elasticsearch elastic_password \
    --value="${ELASTIC_PASSWORD}" \
    >> "${LOG_DIR}/app-install.log" 2>&1 || true
  log_success "Elasticsearch Full Text Search configured."
fi

# Whiteboard
log_info "Waiting for Whiteboard..."
for i in $(seq 1 12); do
  if curl -sf http://127.0.0.1:3002/ 2>/dev/null | grep -qi "whiteboard"; then break; fi
  sleep 5
done
if curl -s http://127.0.0.1:3002/ 2>/dev/null | grep -qi "whiteboard"; then
  $OCC app:install whiteboard >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable whiteboard 2>/dev/null || true
  $OCC config:app:set whiteboard collabBackendUrl --value="https://${NC_DOMAIN}" 2>/dev/null || true
  $OCC config:app:set whiteboard jwt_secret_key   --value="${WHITEBOARD_SECRET}"             2>/dev/null || true
  log_success "Whiteboard configured."
fi

# Memories (photo gallery & timeline)
$OCC app:install memories >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable memories 2>/dev/null || true

# Preview Generator (pre-generate thumbnails)
$OCC app:install previewgenerator >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable previewgenerator 2>/dev/null || true

# Euro-Office Document Server
log_info "Waiting for Euro-Office Document Server..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9980/healthcheck 2>/dev/null | grep -qi "true"; then
    break
  fi
  sleep 5
done
if curl -sf http://127.0.0.1:9980/healthcheck 2>/dev/null | grep -qi "true"; then
  $OCC app:install eurooffice >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable eurooffice 2>/dev/null || true
  $OCC config:app:set eurooffice DocumentServerUrl     --value="https://${NC_DOMAIN}/eurooffice/"             2>/dev/null || true
  $OCC config:app:set eurooffice DocumentServerInternalUrl --value="http://127.0.0.1:9980/"                   2>/dev/null || true
  $OCC config:app:set eurooffice storageUrl             --value="https://${NC_DOMAIN}"                        2>/dev/null || true
  $OCC config:app:set eurooffice jwt_secret            --value="${EUROOFFICE_JWT_SECRET}"                     2>/dev/null || true
  $OCC config:app:set eurooffice jwt_header            --value="AuthorizationJwt"                             2>/dev/null || true
  $OCC config:system:set allow_local_remote_servers   --value="true"                                         2>/dev/null || true
  log_success "Euro-Office Document Server configured."
else
  log_warn "Euro-Office not responding on :9980 -- skipping config."
fi

# Talk Recording
log_info "Waiting for Talk Recording server..."
for i in $(seq 1 60); do
  if curl -s http://127.0.0.1:1234/api/v1/welcome 2>/dev/null | grep -qi "version\|recording\|welcome"; then
    break
  fi
  sleep 5
done
if curl -s http://127.0.0.1:1234/api/v1/welcome 2>/dev/null | grep -qi "version\|recording\|welcome"; then
  $OCC config:app:set spreed recording_backend --value="internal" 2>/dev/null || true
  $OCC config:app:set spreed recording_servers \
    --value="{\"servers\":[{\"server\":\"https://${NC_DOMAIN}/recording\",\"secret\":\"${RECORDING_SECRET}\",\"verify\":false}],\"secret\":\"${RECORDING_SECRET}\"}" \
    2>/dev/null || true
  log_success "Talk Recording configured."
else
  log_warn "Talk Recording not responding on :1234 -- skipping config."
fi

# AppAPI (HaRP - recommended) or Docker Socket Proxy (fallback)
log_info "Waiting for AppAPI/HaRP..."
for i in $(seq 1 60); do
  if curl -s http://127.0.0.1:8780/ 2>/dev/null | grep -qi "not found\|harp\|ok"; then
    break
  fi
  sleep 5
done
if curl -s http://127.0.0.1:8780/ 2>/dev/null | grep -qi "not found\|harp\|ok"; then
  $OCC app:install app_api >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable app_api 2>/dev/null || true
  $OCC app_api:daemon:register \
    --net=host \
    --set-default \
    --harp \
    --harp_frp_address '127.0.0.1:8782' \
    --harp_shared_key "${HARP_SHARED_KEY}" \
    harp_local "HaRP Proxy (Host)" docker-install \
    http "127.0.0.1:8780" "https://${NC_DOMAIN}" 2>&1 || true
  log_success "AppAPI configured with HaRP."
elif curl -s http://127.0.0.1:2375/version 2>/dev/null | grep -q "ApiVersion\|Version"; then
  $OCC app:install app_api >> "${LOG_DIR}/app-install.log" 2>&1 || $OCC app:enable app_api 2>/dev/null || true
  $OCC app_api:daemon:register \
    --net=host \
    --set-default \
    docker_local_sock "Docker Local (Socket Proxy)" docker-install \
    http "127.0.0.1:2375" "https://${NC_DOMAIN}" 2>&1 || true
  log_success "AppAPI configured with Docker Socket Proxy (fallback)."
fi

# Apache proxy for Whiteboard WebSocket, Talk Recording, and HaRP ExApps
for CONF in /etc/apache2/sites-available/nextcloud-le-ssl.conf \
            /etc/apache2/sites-available/nextcloud.conf; do
  if [[ -f "${CONF}" ]]; then
    python3 -c "
path = '${CONF}'
with open(path) as f:
    c = f.read()
injected = False
# Whiteboard: /socket.io/
if '/socket.io/' not in c:
    inject = '    # Whiteboard WebSocket\n    RewriteEngine On\n    RewriteCond %{HTTP:Upgrade} =websocket [NC]\n    RewriteRule /socket.io/(.*) ws://127.0.0.1:3002/socket.io/\$1 [P,L]\n    RewriteCond %{HTTP:Upgrade} !=websocket [NC]\n    RewriteRule /socket.io/(.*) http://127.0.0.1:3002/socket.io/\$1 [P,L]\n    ProxyPassReverse /socket.io/ http://127.0.0.1:3002/socket.io/\n'
    c = c.replace('</VirtualHost>', inject + '</VirtualHost>', 1)
    injected = True
# Talk Recording proxy
if '/recording/' not in c:
    inject = '    # Talk Recording server\n    ProxyPass        /recording/ http://127.0.0.1:1234/\n    ProxyPassReverse /recording/ http://127.0.0.1:1234/\n'
    c = c.replace('</VirtualHost>', inject + '</VirtualHost>', 1)
    injected = True
# HaRP ExApps proxy
if '/exapps/' not in c:
    inject = '    # HaRP ExApps proxy\n    ProxyPass        /exapps/ http://127.0.0.1:8780/exapps/\n    ProxyPassReverse /exapps/ http://127.0.0.1:8780/exapps/\n'
    c = c.replace('</VirtualHost>', inject + '</VirtualHost>', 1)
    injected = True
if injected:
    import tempfile, os
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, 'w') as f:
        f.write(c)
    os.rename(tmp, path)
    print(f'Updated: {path}')
else:
    print(f'Already configured: {path}')
"
  fi
done
apache2ctl configtest >> "${LOG_DIR}/app-install.log" 2>&1 && systemctl reload apache2 || true

# DB indices & repair
$OCC db:add-missing-indices       >> "${LOG_DIR}/app-install.log" 2>&1 || true
$OCC maintenance:repair --include-expensive >> "${LOG_DIR}/app-install.log" 2>&1 || true
$OCC maintenance:update:htaccess  >> "${LOG_DIR}/app-install.log" 2>&1 || true

log_success "Nextcloud install complete."

# ============================================================
log_step "Step 17: High-performance backend (HPB) for Talk"
# ============================================================
# Try APT install from the Morph027 repository first.
# If APT fails, fall back to Docker.

log_info "Installing HPB via APT (Morph027 repository)..."

curl -sL -o /etc/apt/trusted.gpg.d/morph027-nextcloud-spreed-signaling.asc \
  https://packaging.gitlab.io/nextcloud-spreed-signaling/gpg.key 2>/dev/null || \
wget -q -O /etc/apt/trusted.gpg.d/morph027-nextcloud-spreed-signaling.asc \
  https://packaging.gitlab.io/nextcloud-spreed-signaling/gpg.key

echo "deb [arch=amd64] https://packaging.gitlab.io/nextcloud-spreed-signaling signaling main" \
  > /etc/apt/sources.list.d/morph027-nextcloud-spreed-signaling.list

apt-get update -qq

# NATS server is required by the signaling server.
log_info "Installing NATS server..."
apt-get install -y -qq nats-server
systemctl enable --now nats-server
sleep 2

HPB_METHOD=""

if apt-get install -y -qq nextcloud-spreed-signaling morph027-keyring; then
  log_success "HPB installed via APT."
  HPB_METHOD="apt"

  mkdir -p /etc/signaling

  # Write a clean server.conf from scratch.
  # The package ships a heavily-commented template; patching it with sed is
  # fragile because comment formats vary between versions. Writing the full
  # minimal config avoids duplicate-section problems entirely.
  SIGNALING_HASHKEY=$(openssl rand -hex 32)
  SIGNALING_BLOCKKEY=$(python3 -c "import secrets; print(secrets.token_hex(16))")

  # Write server.conf via python3 to guarantee a clean single-instance config.
  python3 - <<PYEOF2
import os, tempfile
hashkey   = "${SIGNALING_HASHKEY}"
blockkey  = "${SIGNALING_BLOCKKEY}"
nc_domain = "${NC_DOMAIN}"
secret    = "${SIGNALING_SECRET}"
isecret   = "${INTERNAL_SECRET}"
config = "[http]\nlisten = 127.0.0.1:8081\n\n[nats]\nurl = nats://localhost:4222\n\n[sessions]\nhashkey = {h}\nblockkey = {b}\n\n[backend]\nbackendtype = static\nbackends = nextcloud-backend\ntimeout = 10\nconnectionsperhost = 8\nallowall = false\n\n[nextcloud-backend]\nurls = https://{d}\nsecret = {s}\n\n[clients]\ninternalsecret = {i}\n\n[turn]\nservers = stun:{d}:3478,turn:{d}:3478\napikey = {t}\nsecret = {t}\n".format(h=hashkey,b=blockkey,d=nc_domain,s=secret,i=isecret,t="${TURN_SECRET}")
fd, tmp = tempfile.mkstemp(dir="/etc/signaling")
with os.fdopen(fd, 'w') as f:
    f.write(config)
os.rename(tmp, "/etc/signaling/server.conf")
os.chmod("/etc/signaling/server.conf", 0o644)
print("server.conf written.")
PYEOF2

  systemctl enable --now signaling 2>/dev/null \
    || systemctl enable --now nextcloud-spreed-signaling 2>/dev/null
  sleep 5
  systemctl restart signaling 2>/dev/null \
    || systemctl restart nextcloud-spreed-signaling 2>/dev/null
  sleep 5

  # Register HPB in Nextcloud (APT branch).
  # Use config:app:delete to remove ALL existing entries before adding,
  # preventing the "multiple HPB" deprecation warning on re-runs.
  log_info "Registering HPB in Nextcloud..."
  $OCC config:app:delete spreed signaling_servers 2>/dev/null || true
  sleep 1
  if $OCC talk:signaling:add \
    "wss://${NC_DOMAIN}/standalone-signaling" \
    "${SIGNALING_SECRET}" >> "${LOG_DIR}/hpb.log" 2>&1; then
    log_success "HPB registered in Nextcloud."
  else
    log_warn "HPB registration failed -- fallback to config:set"
    $OCC config:app:set spreed signaling_servers \
      --value='[{"url":"https://'"${NC_DOMAIN}"'/standalone-signaling","secret":"'"${SIGNALING_SECRET}"'","verify":false}]' \
      2>/dev/null || true
  fi

  sleep 3
  if curl -s -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:8081/api/v1/welcome 2>/dev/null | grep -q "200"; then
    log_success "HPB is responding on port 8081."
  else
    log_warn "HPB not responding. Check: journalctl -u signaling -n 30 --no-pager"
  fi

else
  # -- Docker fallback -----------------------------------------
  log_warn "APT install failed -- falling back to Docker."
  HPB_METHOD="docker"

  if ! command -v docker &>/dev/null; then
    log_error "Docker is required but not installed. Install Docker first."
    exit 1
  fi

  mkdir -p /opt/talk-hpb/config
  cd /opt/talk-hpb

  # SIGNALING_SECRET already set from Step 14.
  # Reuse the INTERNAL_SECRET already generated (don't regenerate)

  cat > docker-compose.yml <<COMPOSEEOF
services:
  nats:
    image: nats:latest
    restart: unless-stopped
    network_mode: host

  janus:
    image: canyan/janus-gateway:latest
    network_mode: host
    restart: unless-stopped
    environment:
      - JANUS_RTP_PORT_RANGE=20000-40000

  signaling:
    image: strukturag/nextcloud-spreed-signaling:latest
    network_mode: host
    depends_on:
      - nats
      - janus
    volumes:
      - /opt/talk-hpb/config/server.conf:/config/server.conf:ro
    environment:
      - CONFIG_FILE=/config/server.conf
    restart: unless-stopped
COMPOSEEOF

  cat > config/server.conf <<SIGCONF
[http]
listen = 127.0.0.1:8081

[app]
secret = ${INTERNAL_SECRET}

[nats]
url = nats://127.0.0.1:4222

[mcu]
type = janus
url = ws://127.0.0.1:8188

[backend]
backends = nextcloud-backend

[backend.nextcloud-backend]
url = https://${NC_DOMAIN}
secret = ${SIGNALING_SECRET}

[turn]
api = static
secret = ${TURN_SECRET}
servers = turn:${NC_DOMAIN}:3478?transport=udp,turn:${NC_DOMAIN}:3478?transport=tcp
SIGCONF

  docker compose up -d
  sleep 10

  # Register HPB in Nextcloud (Docker branch).
  log_info "Registering HPB (Docker) in Nextcloud..."
  $OCC config:app:delete spreed signaling_servers 2>/dev/null || true
  sleep 1
  if $OCC talk:signaling:add \
    "wss://${NC_DOMAIN}/standalone-signaling" \
    "${SIGNALING_SECRET}" >> "${LOG_DIR}/hpb.log" 2>&1; then
    log_success "HPB (Docker) registered in Nextcloud."
  else
    log_warn "HPB registration failed -- fallback to config:set"
    $OCC config:app:set spreed signaling_servers \
      --value='[{"url":"https://'"${NC_DOMAIN}"'/standalone-signaling","secret":"'"${SIGNALING_SECRET}"'","verify":false}]' \
      2>/dev/null || true
  fi

  if curl -s -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:8081/api/v1/welcome 2>/dev/null | grep -q "200"; then
    log_success "HPB (Docker) is responding on port 8081."
  else
    log_warn "HPB (Docker) not responding. Check: docker compose -f /opt/talk-hpb/docker-compose.yml logs"
  fi

  log_success "HPB (Docker) installed."
fi

# Save HPB method to .env for reference.
echo "HPB_METHOD=${HPB_METHOD}" >> "${PROJECT_DIR}/.env"

# ============================================================
log_step "Step 18: Fix Imagick SVG support"
# ============================================================
apt-get install -y -qq libmagickwand-dev 2>/dev/null || true
if command -v pecl &>/dev/null; then
  pecl install --quiet imagick <<< "yes" || true
  systemctl restart php8.3-fpm
  log_success "Imagick rebuilt with SVG support."
else
  log_warn "pecl not found -- skipping Imagick rebuild."
fi

# ============================================================
log_step "Step 19: Cron jobs"
# ============================================================
# Nextcloud background jobs -- every 5 minutes.
echo "*/5 * * * * www-data php -f ${NCWWW_DIR}/cron.php > /dev/null 2>&1" \
  > /etc/cron.d/nextcloud
chmod 644 /etc/cron.d/nextcloud
$OCC background:cron || true

# Force one immediate cron run so "last run" is populated.
sudo -u www-data php "${NCWWW_DIR}/cron.php" 2>/dev/null || true
log_success "Nextcloud cron configured and executed once."

# Calendar reminders -- separate job, every 5 minutes.
echo "*/5 * * * * www-data php -f ${NCWWW_DIR}/occ dav:send-event-reminders > /dev/null 2>&1" \
  > /etc/cron.d/nextcloud-calendar
chmod 644 /etc/cron.d/nextcloud-calendar

# SSL auto-renew -- twice daily (midnight and noon).
echo "0 0,12 * * * root certbot renew --quiet --deploy-hook 'systemctl reload apache2'" \
  > /etc/cron.d/certbot-nextcloud
chmod 644 /etc/cron.d/certbot-nextcloud

log_success "All cron jobs configured."

# ============================================================
log_step "Step 20: Auto-update script"
# ============================================================
cat > "${PROJECT_DIR}/auto-update.sh" <<'UPDATEEOF'
#!/bin/bash
set -eo pipefail
NCWWW_DIR="/var/www/nextcloud"
LOG_FILE="/var/log/nextcloud/autoupdate.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
log() { echo "[${TIMESTAMP}] $1" | tee -a "${LOG_FILE}"; }
OCC="sudo -u www-data php ${NCWWW_DIR}/occ"

cleanup() {
  $OCC maintenance:mode --off 2>/dev/null || true
}
trap cleanup EXIT TERM HUP INT

log "===================================="
log "Starting Nextcloud update check..."

# -- 1. Nextcloud core upgrade -----------------------------------
$OCC maintenance:mode --on  >> "${LOG_FILE}" 2>&1
$OCC upgrade --no-interaction >> "${LOG_FILE}" 2>&1 || true

# -- 2. All Nextcloud apps update --------------------------------
$OCC app:update --all        >> "${LOG_FILE}" 2>&1 || true

# -- 3. Maintenance repair & htaccess ----------------------------
$OCC maintenance:repair --include-expensive >> "${LOG_FILE}" 2>&1 || true
$OCC maintenance:update:htaccess >> "${LOG_FILE}" 2>&1 || true

# -- 4. Restart bare-metal services (order: Redis → PHP → others) -
systemctl restart redis-server                 2>/dev/null || true
systemctl restart php8.3-fpm                   2>/dev/null || true
systemctl restart apache2                      2>/dev/null || true
systemctl restart notify_push                  2>/dev/null || true
systemctl restart signaling                    2>/dev/null || true
systemctl restart nextcloud-spreed-signaling   2>/dev/null || true
systemctl restart coturn                       2>/dev/null || true

# -- 5. Update Docker services (pull + recreate) -----------------
DOCKER_DIR="/opt/nextcloud-docker"
if [[ -d "${DOCKER_DIR}" ]] && command -v docker &>/dev/null; then
  log "Updating Docker services..."
  docker compose -f "${DOCKER_DIR}/docker-compose.yml" pull --quiet  >> "${LOG_FILE}" 2>&1 || true
  docker compose -f "${DOCKER_DIR}/docker-compose.yml" up -d --remove-orphans >> "${LOG_FILE}" 2>&1 || true
  docker image prune -f >> "${LOG_FILE}" 2>&1 || true
  log "Docker services updated."
fi

# -- 6. Update HPB Docker (if installed via Docker) ---------------
HPB_COMPOSE="/opt/talk-hpb/docker-compose.yml"
if [[ -d "/opt/talk-hpb" ]] && command -v docker &>/dev/null; then
  docker compose -f "${HPB_COMPOSE}" pull --quiet  >> "${LOG_FILE}" 2>&1 || true
  docker compose -f "${HPB_COMPOSE}" up -d --remove-orphans >> "${LOG_FILE}" 2>&1 || true
fi

# -- 7. SSL renewal (certbot) ------------------------------------
certbot renew --quiet >> "${LOG_FILE}" 2>&1 || true

# -- 8. Disable maintenance mode ---------------------------------
$OCC maintenance:mode --off >> "${LOG_FILE}" 2>&1

log "Update routine finished."
log "===================================="
UPDATEEOF
chmod +x "${PROJECT_DIR}/auto-update.sh"

echo "0 3 * * * root /opt/nextcloud/auto-update.sh" \
  > /etc/cron.d/nextcloud-autoupdate
chmod 644 /etc/cron.d/nextcloud-autoupdate
log_success "Auto-update script registered (daily 03:00 AM)."

# Full Text Search auto-index (every 15 minutes)
echo "*/15 * * * * www-data php -f ${NCWWW_DIR}/occ fulltextsearch:index > /dev/null 2>&1" \
  > /etc/cron.d/nextcloud-fulltextsearch
chmod 644 /etc/cron.d/nextcloud-fulltextsearch
log_success "Full Text Search auto-index registered (every 15 minutes)."

# ============================================================
log_step "Step 21: Backup system (BorgBackup)"
# ============================================================
cat > "${PROJECT_DIR}/backup.sh" <<BORGEOF
#!/bin/bash
set -eo pipefail
source /opt/nextcloud/.env
export PGPASSWORD="\${NC_DB_PASS}"
export BORG_PASSPHRASE="\${BORG_PASSPHRASE}"
NCWWW_DIR="/var/www/nextcloud"
NCDATA_DIR="/var/nextcloud-data"
BACKUP_DIR="/opt/nextcloud/backups"
BORG_REPO="\${BACKUP_DIR}/borg"
LOG_FILE="/var/log/nextcloud/backup.log"
RETAIN_DAYS=7
TIMESTAMP=\$(date '+%Y-%m-%d_%H-%M-%S')
OCC="sudo -u www-data php \${NCWWW_DIR}/occ"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\${LOG_FILE}"; }

cleanup() {
  \$OCC maintenance:mode --off 2>/dev/null || true
}
trap cleanup EXIT TERM HUP INT

log "===================================="
log "Starting backup: \${TIMESTAMP}"

\$OCC maintenance:mode --on
log "Maintenance mode ON."

if [ ! -d "\${BORG_REPO}" ]; then
  borg init --encryption=repokey "\${BORG_REPO}"
  log "Borg repo initialized."
fi

borg create \
  --compression lz4 \
  --exclude-caches \
  "\${BORG_REPO}::\${TIMESTAMP}" \
  "\${NCDATA_DIR}" \
  "\${NCWWW_DIR}/config" \
  >> "\${LOG_FILE}" 2>&1

pg_dump -U "\${NC_DB_USER}" -h 127.0.0.1 "\${NC_DB}" \
  | gzip > "\${BACKUP_DIR}/nc_db_\${TIMESTAMP}.sql.gz"

DB_SIZE=\$(stat -c%s "\${BACKUP_DIR}/nc_db_\${TIMESTAMP}.sql.gz" 2>/dev/null || echo 0)
if [ "\${DB_SIZE}" -lt 100 ]; then
  log "ERROR: pg_dump produced empty/invalid backup (\${DB_SIZE} bytes)"
  rm -f "\${BACKUP_DIR}/nc_db_\${TIMESTAMP}.sql.gz"
fi

SIZE=\$(borg info "\${BORG_REPO}::\${TIMESTAMP}" 2>/dev/null \
  | grep "Compressed size" | awk '{print \$3,\$4}' || echo "N/A")
log "Backup created: \${TIMESTAMP} (\${SIZE})"

borg prune \
  --keep-daily=\${RETAIN_DAYS} \
  --keep-weekly=4 \
  --keep-monthly=3 \
  "\${BORG_REPO}" >> "\${LOG_FILE}" 2>&1 || true

find "\${BACKUP_DIR}" -name "nc_db_*.sql.gz" \
  -mtime +\${RETAIN_DAYS} -delete 2>/dev/null || true

\$OCC maintenance:mode --off
log "Maintenance mode OFF."
log "Backup completed."
log "===================================="
BORGEOF
chmod +x "${PROJECT_DIR}/backup.sh"

cat > "${PROJECT_DIR}/backup-manager.sh" <<'MANAGEREOF'
#!/bin/bash
CRON_FILE="/etc/cron.d/nextcloud-backup"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
case "$1" in
  enable)
    if [ -f "${CRON_FILE}" ]; then
      echo -e "${YELLOW}[WARN]${NC}  Auto-backup already enabled."
    else
      echo "0 2 * * * root /opt/nextcloud/backup.sh >> /var/log/nextcloud/backup.log 2>&1" \
        > "${CRON_FILE}"
      chmod 644 "${CRON_FILE}"
      echo -e "${GREEN}[OK]${NC}    Auto-backup enabled -- daily at 02:00 AM."
    fi
    ;;
  disable)
    rm -f "${CRON_FILE}"
    echo -e "${GREEN}[OK]${NC}    Auto-backup disabled."
    ;;
  status)
    if [ -f "${CRON_FILE}" ]; then
      echo -e "${GREEN}[ON]${NC}    Auto-backup ENABLED (daily 02:00 AM)."
      COUNT=$(ls /opt/nextcloud/backups/borg 2>/dev/null | wc -l || echo 0)
      SIZE=$(du -sh /opt/nextcloud/backups 2>/dev/null | cut -f1 || echo "0")
      echo -e "${CYAN}        Backups: ${COUNT} archive(s) -- ${SIZE}${NC}"
    else
      echo -e "${YELLOW}[OFF]${NC}   Auto-backup DISABLED."
    fi
    ;;
  now)
    echo -e "${CYAN}[INFO]${NC}  Running manual backup..."
    bash /opt/nextcloud/backup.sh
    ;;
  restore)
    BORG_REPO="/opt/nextcloud/backups/borg"
    echo "Available archives:"
    borg list "${BORG_REPO}"
    echo ""
    echo "To restore: borg extract ${BORG_REPO}::ARCHIVE_NAME"
    ;;
  *)
    echo ""
    echo "  Usage: bash /opt/nextcloud/backup-manager.sh [command]"
    echo ""
    echo "  Commands:"
    echo "    enable   -- Enable daily auto-backup (02:00 AM)"
    echo "    disable  -- Disable auto-backup"
    echo "    status   -- Show backup status"
    echo "    now      -- Run manual backup immediately"
    echo "    restore  -- Show restore instructions"
    echo ""
    ;;
esac
MANAGEREOF
chmod +x "${PROJECT_DIR}/backup-manager.sh"
log_success "BorgBackup scripts created (auto-backup: disabled by default)."

# ============================================================
log_step "Step 21b: Log rotation"
# ============================================================
cat > /etc/logrotate.d/nextcloud <<'LOGROTATE'
/var/log/nextcloud/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data www-data
    sharedscripts
    postrotate
        [ -f /var/run/apache2/apache2.pid ] && kill -USR1 $(cat /var/run/apache2/apache2.pid) 2>/dev/null || true
    endscript
}
LOGROTATE
log_success "Log rotation configured (14 days)."

log_step "Step 22: Final service restart & checks"
# ============================================================
# Nextcloud is already fully installed and configured by Step 16
# (occ maintenance:install, no web wizard). Just restart services.

systemctl restart redis-server 2>/dev/null || true
systemctl restart php8.3-fpm 2>/dev/null || true
systemctl restart apache2 2>/dev/null || true
systemctl restart signaling 2>/dev/null \
  || systemctl restart nextcloud-spreed-signaling 2>/dev/null || true
sleep 3
log_success "Infrastructure services restarted."

if systemctl is-active --quiet signaling 2>/dev/null \
  || systemctl is-active --quiet nextcloud-spreed-signaling 2>/dev/null \
  || (command -v docker &>/dev/null && docker ps 2>/dev/null | grep -q signaling); then
  log_success "High-performance backend is running."
else
  log_warn "HPB not active -- check manually."
fi


TOTAL_TIME=$(elapsed)

# ============================================================
# Final summary
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}|        Nextcloud is installed and running               |${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  URL:              ${CYAN}https://${NC_DOMAIN}${NC}"
echo -e "  Admin username:   ${CYAN}${NC_ADMIN_USER}${NC}"
echo -e "  Admin password:   ${CYAN}${NC_ADMIN_PASS}${NC}"
echo -e "  SSL:              ${CYAN}Let's Encrypt (auto-renew: twice daily)${NC}"
echo -e "  Database:         ${CYAN}PostgreSQL -- ${NC_DB}${NC}"
echo -e "  Timezone:         ${CYAN}${DETECTED_TZ}${NC}"
echo -e "  Install time:     ${CYAN}${TOTAL_TIME}${NC}"
echo ""
echo -e "${BOLD}Stack:${NC}"
echo -e "  PHP:              ${CYAN}8.3 + OPcache/JIT + APCu (Sury)${NC}"
echo -e "  Cache:            ${CYAN}Redis (socket or TCP) + APCu${NC}"
echo -e "  Push:             ${CYAN}notify_push (arch: $(uname -m))${NC}"
echo -e "  TURN:             ${CYAN}coturn :3478 TCP/UDP${NC}"
echo -e "  HPB (Talk):       ${CYAN}${HPB_METHOD} method${NC}"
echo -e "  Backup:           ${CYAN}BorgBackup (disabled by default)${NC}"
echo ""
echo -e "${BOLD}Docker services (/opt/nextcloud-docker/):${NC}"
echo -e "  ${CYAN}Imaginary          -- image preview :9000${NC}"
echo -e "  ${CYAN}Elasticsearch      -- full text search :9200${NC}"
echo -e "  ${CYAN}Whiteboard         -- collaborative whiteboard :3002${NC}"
echo -e "  ${CYAN}Euro-Office        -- online office editing :9980${NC}"
echo -e "  ${CYAN}Talk Recording     -- call recording :1234${NC}"
echo -e "  ${CYAN}Janus              -- WebRTC gateway${NC}"
echo -e "  ${CYAN}Docker Socket Proxy-- AppAPI access :2375${NC}"
echo -e "  ${CYAN}Watchtower         -- auto-updates Docker images (daily 03:00)${NC}"
echo ""
echo -e "  Manage: ${CYAN}docker compose -f /opt/nextcloud-docker/docker-compose.yml [ps|logs|restart]${NC}"
echo ""
echo -e "${BOLD}Installed apps:${NC}"
echo -e "  ${CYAN}Talk               -- spreed${NC}"
echo -e "  ${CYAN}Calendar           -- calendar${NC}"
echo -e "  ${CYAN}Contacts           -- contacts${NC}"
echo -e "  ${CYAN}Mail               -- mail${NC}"
echo -e "  ${CYAN}Office (Euro)      -- eurooffice${NC}"
echo -e "  ${CYAN}Assistant          -- assistant${NC}"
echo -e "  ${CYAN}Flow               -- flow_notifications${NC}"
echo -e "  ${CYAN}Deck               -- deck${NC}"
echo -e "  ${CYAN}Push Notification  -- notify_push${NC}"
echo -e "  ${CYAN}2FA TOTP           -- twofactor_totp${NC}"
echo -e "  ${CYAN}External Storage   -- files_external (enabled)${NC}"
echo -e "  ${CYAN}2FA via Notif.     -- twofactor_nextcloud_notification (enabled)${NC}"
echo ""
echo -e "${BOLD}Cron jobs:${NC}"
echo -e "  ${CYAN}/etc/cron.d/nextcloud            -- background jobs (5 min)${NC}"
echo -e "  ${CYAN}/etc/cron.d/nextcloud-calendar   -- calendar reminders (5 min)${NC}"
echo -e "  ${CYAN}/etc/cron.d/nextcloud-autoupdate -- auto-update (daily 03:00)${NC}"
echo -e "  ${CYAN}/etc/cron.d/nextcloud-fulltextsearch -- FTS index (every 15 min)${NC}"
echo -e "  ${CYAN}/etc/cron.d/certbot-nextcloud    -- SSL renew (twice daily)${NC}"
echo ""
echo -e "${BOLD}Files:${NC}"
echo -e "  Web root:         ${CYAN}${NCWWW_DIR}${NC}"
echo -e "  Data dir:         ${CYAN}${NCDATA_DIR}${NC}"
echo -e "  Project:          ${CYAN}${PROJECT_DIR}${NC}"
echo -e "  Secrets:          ${CYAN}${PROJECT_DIR}/.env${NC}"
echo -e "  Logs:             ${CYAN}${LOG_DIR}/${NC}"
echo ""
echo -e "${BOLD}Backup management:${NC}"
echo -e "  ${CYAN}bash ${PROJECT_DIR}/backup-manager.sh enable${NC}"
echo -e "  ${CYAN}bash ${PROJECT_DIR}/backup-manager.sh now${NC}"
echo -e "  ${CYAN}bash ${PROJECT_DIR}/backup-manager.sh status${NC}"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo -e "  occ:              ${CYAN}sudo -u www-data php ${NCWWW_DIR}/occ${NC}"
echo -e "  App list:         ${CYAN}sudo -u www-data php ${NCWWW_DIR}/occ app:list${NC}"
echo -e "  Push test:        ${CYAN}sudo -u www-data php ${NCWWW_DIR}/occ notification:test-push admin${NC}"
echo -e "  Push self-test:   ${CYAN}sudo -u www-data php ${NCWWW_DIR}/occ notify_push:self-test${NC}"
echo -e "  TURN status:      ${CYAN}systemctl status coturn${NC}"
echo -e "  Push status:      ${CYAN}systemctl status notify_push${NC}"
echo -e "  HPB status:       ${CYAN}systemctl status signaling${NC}"
echo -e "  Apache logs:      ${CYAN}tail -f /var/log/apache2/nextcloud_error.log${NC}"
echo -e "  Update logs:      ${CYAN}tail -f ${LOG_DIR}/autoupdate.log${NC}"
echo -e "  Manual update:    ${CYAN}bash ${PROJECT_DIR}/auto-update.sh${NC}"
echo ""
echo ""
echo -e "${YELLOW}  [!]  Euro-Office Document Server is running on :9980${NC}"
echo -e "${YELLOW}       First edit may take a few minutes as the container initializes.${NC}"
echo ""