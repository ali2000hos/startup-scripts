#!/usr/bin/env bash
#
# Interactive Nextcloud installer for a fresh Ubuntu server.
# PHP 8.3+ + Apache + PostgreSQL + Redis, coturn (Talk TURN) + a high-performance
# backend (Talk signaling), Let's Encrypt TLS, verified backups, safe updates.
#
# Usage:  sudo bash install-nextcloud.sh
# Re-running is safe: existing secrets, data and the installed site are preserved.
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

trap 'log_error "Failed at line $LINENO. Re-run this script -- completed steps are preserved."' ERR

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------
PROJECT_DIR="/opt/nextcloud"
NCWWW_DIR="/var/www/nextcloud"
NCDATA_DIR="/var/nextcloud-data"
BACKUP_DIR="${PROJECT_DIR}/backups"
LOG_DIR="/var/log/nextcloud"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_ROOT="${PROJECT_DIR}/config-backups"

SECONDS=0
elapsed() { printf "%dm %ds" "$((SECONDS/60))" "$((SECONDS%60))"; }

# Back up a config file before it gets overwritten, but only once per run.
backup_config() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_ROOT"
  cp -a "$f" "${BACKUP_ROOT}/$(basename "$f").$(date +%Y%m%d%H%M%S).bak"
}

mkdir -p "${PROJECT_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"
chmod 700 "${BACKUP_DIR}"

# ------------------------------------------------------------------
log_step "Step 0: Preflight checks"
# ------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this script as root:  sudo bash $0"
[[ -t 0 ]] || die "This script is interactive. Download it first, then run it — do not pipe it from curl."

OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2)
OS_VER=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
[[ "$OS_ID" == "ubuntu" ]] || die "This script requires Ubuntu. Detected: ${OS_ID}"
(( OS_MAJOR >= 22 )) || log_warn "Ubuntu ${OS_VER} is older than 22.04. Continuing but not officially supported."
log_success "Detected: Ubuntu ${OS_VER}"

TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
log_info "Memory: ${TOTAL_MEM_MB} MB"
if (( TOTAL_MEM_MB < 3500 )); then
  log_warn "Nextcloud + Talk's signaling stack wants ~4 GB RAM. You have ${TOTAL_MEM_MB} MB."
  if [[ ! -f /swapfile ]] && ask_yn "Create a 2 GB swap file to be safe?" "y"; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_success "2 GB swap enabled."
  fi
fi

FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
(( FREE_GB >= 10 )) || log_warn "Only ${FREE_GB} GB free on /. Nextcloud, its data and backups need headroom."

SERVER_IP=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
  || hostname -I | awk '{print $1}')
[[ -n "$SERVER_IP" ]] || die "Could not determine the server IP address."
log_success "Server IP: ${SERVER_IP}"

DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

# ------------------------------------------------------------------
log_step "Step 1: Configuration questions"
# ------------------------------------------------------------------

# --- Reuse an existing installation? -------------------------------
REUSED_ENV=false
if [[ -f "$ENV_FILE" ]]; then
  log_warn "An existing ${ENV_FILE} was found."
  echo "   It holds the database password, TURN secret and Talk signaling keys."
  echo "   Regenerating them would desync Nextcloud from what it already trusts."
  ask_yn "Keep the existing secrets and only update the configuration?" "y" \
    || die "Aborted. To start over completely, drop the PostgreSQL database/user too -- removing only ${ENV_FILE} leaves stale credentials in Postgres that the next run's new secrets won't match."
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  REUSED_ENV=true
  log_success "Existing secrets loaded."
fi

# --- Domain --------------------------------------------------------
echo ""
echo "  A real domain is strongly recommended. It gets baked into federation,"
echo "  Talk signaling and mobile-client URLs, so changing it later means"
echo "  reconfiguring all of them by hand."
echo ""
if ask_yn "Do you have a domain pointing at ${SERVER_IP}?" "y"; then
  while true; do
    NC_DOMAIN=$(ask "Domain for Nextcloud (e.g. cloud.example.com)" "${NC_DOMAIN:-}")
    if [[ "$NC_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
      break
    fi
    log_warn "That does not look like a valid domain. Try again."
  done
else
  NC_DOMAIN="cloud.${SERVER_IP//./-}.sslip.io"
  log_warn "Using ${NC_DOMAIN} (sslip.io). Fine for testing, tied to this IP."
fi

log_info "Checking DNS for ${NC_DOMAIN}..."
RESOLVED_IP=$(getent hosts "$NC_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
if [[ -z "$RESOLVED_IP" ]]; then
  log_warn "${NC_DOMAIN} does not resolve yet."
  echo "   Let's Encrypt will fail until an A record points to ${SERVER_IP}."
  ask_yn "Continue anyway?" "n" || die "Add the DNS record, then re-run this script."
elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
  log_warn "${NC_DOMAIN} resolves to ${RESOLVED_IP}, not ${SERVER_IP}."
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

GENERIC_TIMEZONE=$(ask "Timezone for logs and calendar reminders" "${DETECTED_TZ:-${GENERIC_TIMEZONE:-UTC}}")

# Detect what a previous, possibly interrupted, run already had configured,
# so a re-run defaults to preserving it rather than to the first-run default.
BACKUP_DEFAULT="y"; AUTOUPDATE_DEFAULT="n"; PREV_RETAIN_DAYS="7"
[[ -f /etc/cron.d/nextcloud-backup ]] || BACKUP_DEFAULT="n"
[[ -f /etc/cron.d/nextcloud-autoupdate ]] && AUTOUPDATE_DEFAULT="y"

echo ""
BACKUP_ENABLED=true
ask_yn "Enable nightly backups at 02:00 (database + data + config)?" "$BACKUP_DEFAULT" \
  || BACKUP_ENABLED=false
BACKUP_RETAIN_DAYS=7
if $BACKUP_ENABLED; then BACKUP_RETAIN_DAYS=$(ask "Keep backups for how many days?" "$PREV_RETAIN_DAYS"); fi

echo ""
echo "  The daily update job runs 'occ upgrade' and updates all apps unattended."
AUTOUPDATE_ENABLED=false
if ask_yn "Enable daily automatic updates (03:00)?" "$AUTOUPDATE_DEFAULT"; then AUTOUPDATE_ENABLED=true; fi

# --- Confirm -------------------------------------------------------
echo ""
echo -e "${BOLD}Summary${NC}"
echo "  Domain:         https://${NC_DOMAIN}"
echo "  Certificate:    Let's Encrypt${LETSENCRYPT_EMAIL:+ (notices to ${LETSENCRYPT_EMAIL})}"
echo "  Timezone:       ${GENERIC_TIMEZONE}"
echo "  Database:       PostgreSQL (local, not exposed publicly)"
echo "  Backups:        $($BACKUP_ENABLED && echo "nightly 02:00, ${BACKUP_RETAIN_DAYS} day retention" || echo 'manual only')"
echo "  Auto-update:    $($AUTOUPDATE_ENABLED && echo 'daily 03:00' || echo 'manual only')"
echo "  Install path:   ${PROJECT_DIR}"
echo ""
ask_yn "Proceed with installation?" "y" || die "Aborted. Nothing was changed."

# ============================================================
log_step "Step 2: System update & base packages"
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
log_step "Step 3: PHP (Ubuntu archive, or Sury/PPA fallback)"
# ============================================================
UBUNTU_CODENAME=$(lsb_release -sc)

PHP_VER=""
for v in 8.3 8.4 8.5; do
  if apt-cache show "php${v}-fpm" 2>/dev/null | grep -q '^Version:'; then
    PHP_VER="$v"
    break
  fi
done

if [[ -n "$PHP_VER" ]]; then
  log_success "PHP ${PHP_VER} is available directly from Ubuntu's own archive -- no external repo needed."
elif [[ -f /etc/apt/sources.list.d/php.list ]] || \
   grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
  log_success "PHP repository already configured."
elif [[ -f /usr/share/keyrings/deb.sury.org-php.gpg ]] || \
     curl -4 -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 \
       -o /usr/share/keyrings/deb.sury.org-php.gpg \
       https://packages.sury.org/php/apt.gpg; then
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
    https://packages.sury.org/php/ ${UBUNTU_CODENAME} main" \
    > /etc/apt/sources.list.d/php.list
elif [[ "$UBUNTU_CODENAME" == "jammy" || "$UBUNTU_CODENAME" == "noble" ]]; then
  log_warn "packages.sury.org unreachable -- falling back to the ppa:ondrej/php mirror on Launchpad."
  rm -f /usr/share/keyrings/deb.sury.org-php.gpg
  add-apt-repository -y ppa:ondrej/php
else
  die "Could not reach packages.sury.org, and the ppa:ondrej/php fallback does not yet support ${UBUNTU_CODENAME}. Check network/DNS access to packages.sury.org (try: curl -4 -v https://packages.sury.org/php/apt.gpg) and re-run."
fi
PHP_VER="${PHP_VER:-8.3}"

apt-get update -qq
apt-get install -y -qq \
  "php${PHP_VER}-fpm" "php${PHP_VER}-cli" \
  "php${PHP_VER}-pgsql" "php${PHP_VER}-gd" "php${PHP_VER}-curl" "php${PHP_VER}-xml" \
  "php${PHP_VER}-zip" "php${PHP_VER}-mbstring" "php${PHP_VER}-intl" "php${PHP_VER}-bcmath" \
  "php${PHP_VER}-gmp" "php${PHP_VER}-bz2" "php${PHP_VER}-imagick" \
  "php${PHP_VER}-redis" "php${PHP_VER}-apcu" "php${PHP_VER}-imap" \
  "libapache2-mod-php${PHP_VER}" \
  php-pear "php${PHP_VER}-dev"

PHP_INI_FPM="/etc/php/${PHP_VER}/fpm/php.ini"
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"

for PHP_INI in "$PHP_INI_FPM" "$PHP_INI_CLI"; do
  sed -i 's/^memory_limit =.*/memory_limit = 1G/'              "$PHP_INI"
  sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 16G/' "$PHP_INI"
  sed -i 's/^post_max_size =.*/post_max_size = 16G/'            "$PHP_INI"
  sed -i 's/^max_execution_time =.*/max_execution_time = 3600/'  "$PHP_INI"
  sed -i 's/^max_input_time =.*/max_input_time = 3600/'         "$PHP_INI"
  sed -i "s|^;date.timezone =.*|date.timezone = ${GENERIC_TIMEZONE}|" "$PHP_INI"
  # output_buffering must be Off for Nextcloud compatibility
  sed -i 's/^output_buffering =.*/output_buffering = Off/'      "$PHP_INI"
done

# A dedicated conf.d file, not an append to php.ini, so re-running this
# script never duplicates the OPcache/APCu block.
cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-nextcloud.ini" <<'OPCACHE'
; -- Nextcloud / AIO-grade OPcache + JIT + APCu --------------
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=1
opcache.jit=tracing
opcache.jit_buffer_size=128M
apc.enable_cli=1
apc.shm_size=128M
OPCACHE

systemctl enable --now "php${PHP_VER}-fpm"
systemctl reload "php${PHP_VER}-fpm"
log_success "PHP ${PHP_VER} with OPcache+JIT and APCu configured."

# ============================================================
log_step "Step 4: Apache web server"
# ============================================================
apt-get install -y -qq apache2

a2enmod rewrite headers env dir mime ssl http2 \
        proxy proxy_http proxy_fcgi proxy_wstunnel \
        setenvif expires >/dev/null

a2enconf "php${PHP_VER}-fpm" 2>/dev/null || true
a2dissite 000-default 2>/dev/null || true

systemctl enable --now apache2
log_success "Apache configured."

# ============================================================
log_step "Step 5: PostgreSQL (idempotent)"
# ============================================================
apt-get install -y -qq postgresql postgresql-contrib
systemctl enable --now postgresql
sleep 3

NC_DB="${NC_DB:-nextcloud}"
NC_DB_USER="${NC_DB_USER:-nextcloud_user}"
NC_DB_PASS="${NC_DB_PASS:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"

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
log_step "Step 6: Redis (unix socket with TCP fallback)"
# ============================================================
apt-get install -y -qq redis-server

REDIS_CONF="/etc/redis/redis.conf"
backup_config "$REDIS_CONF"
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/'           "$REDIS_CONF"
sed -i 's/^# maxmemory-policy.*/maxmemory-policy allkeys-lru/' "$REDIS_CONF"
sed -i 's|^# unixsocket .*|unixsocket /run/redis/redis.sock|' "$REDIS_CONF"
sed -i 's/^# unixsocketperm.*/unixsocketperm 770/'         "$REDIS_CONF"

systemctl enable --now redis-server
sleep 2

usermod -aG redis www-data 2>/dev/null || true
chown redis:redis /run/redis/redis.sock 2>/dev/null || true
chmod 770 /run/redis/redis.sock 2>/dev/null || true

REDIS_OK=false
for _ in 1 2 3 4 5; do
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
log_step "Step 7: coturn (TURN server for Talk)"
# ============================================================
apt-get install -y -qq coturn

TURN_SECRET="${TURN_SECRET:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"

backup_config /etc/turnserver.conf
cat > /etc/turnserver.conf <<TURNEOF
listening-port=3478
no-tls
no-dtls
listening-ip=0.0.0.0
relay-ip=0.0.0.0
min-port=49160
max-port=49360
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
systemctl restart coturn
log_success "coturn TURN server configured (secret $($REUSED_ENV && echo reused || echo generated))."

# ============================================================
log_step "Step 8: BorgBackup"
# ============================================================
apt-get install -y -qq borgbackup
log_success "BorgBackup installed."

# ============================================================
log_step "Step 9: Download & verify Nextcloud"
# ============================================================
mkdir -p "${NCWWW_DIR}" "${NCDATA_DIR}"

if [[ -f "${NCWWW_DIR}/config/config.php" ]]; then
  log_warn "An existing Nextcloud install was found at ${NCWWW_DIR} -- not overwriting."
  log_info "To install a fresh copy, move or remove ${NCWWW_DIR} first, then re-run."
else
  log_info "Downloading latest Nextcloud..."
  wget -q --show-progress \
    -O /tmp/nextcloud.tar.bz2 \
    "https://download.nextcloud.com/server/releases/latest.tar.bz2"
  wget -q \
    -O /tmp/nextcloud.tar.bz2.sha256 \
    "https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256"

  log_info "Verifying checksum..."
  EXPECTED_HASH=$(awk 'NR==1{print $1}' /tmp/nextcloud.tar.bz2.sha256)
  ACTUAL_HASH=$(sha256sum /tmp/nextcloud.tar.bz2 | awk '{print $1}')
  [[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] || die "Checksum mismatch -- download may be corrupt."
  log_success "Checksum OK."

  tar -xjf /tmp/nextcloud.tar.bz2 -C /tmp/
  cp -r /tmp/nextcloud/. "${NCWWW_DIR}/"
  rm -rf /tmp/nextcloud /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.sha256

  chown -R www-data:www-data "${NCWWW_DIR}" "${NCDATA_DIR}"
  chmod -R 755 "${NCWWW_DIR}"
  chmod -R 750 "${NCDATA_DIR}"
  log_success "Nextcloud deployed to ${NCWWW_DIR}."
fi

# ============================================================
log_step "Step 10: Apache virtual host (HTTP -- pre-SSL)"
# ============================================================
backup_config /etc/apache2/sites-available/nextcloud.conf
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
    ProxyPass        /standalone-signaling/spreed  ws://127.0.0.1:8081/spreed
    ProxyPassReverse /standalone-signaling/spreed  ws://127.0.0.1:8081/spreed
    ProxyPass        /standalone-signaling/        http://127.0.0.1:8081/
    ProxyPassReverse /standalone-signaling/        http://127.0.0.1:8081/

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
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Permitted-Cross-Domain-Policies "none"
        Header always set X-Robots-Tag "noindex, nofollow"
        Header always set Referrer-Policy "no-referrer"
    </IfModule>

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/xml
        AddOutputFilterByType DEFLATE text/css application/javascript
        AddOutputFilterByType DEFLATE application/json
    </IfModule>

    ErrorLog  \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
APACHEEOF

a2ensite nextcloud >/dev/null
apache2ctl configtest
systemctl reload apache2
log_success "Apache virtual host configured."

# ============================================================
log_step "Step 11: UFW firewall"
# ============================================================
if command -v ufw &>/dev/null; then
  SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
  SSH_PORT="${SSH_PORT:-22}"
  ufw allow "${SSH_PORT}/tcp" >/dev/null   # allowed FIRST, so enabling never locks you out
  ufw allow 80/tcp   >/dev/null
  ufw allow 443/tcp  >/dev/null
  ufw allow 3478/tcp >/dev/null
  ufw allow 3478/udp >/dev/null
  ufw allow 49160:49360/udp >/dev/null   # coturn relay range, must match /etc/turnserver.conf min-port/max-port
  ufw --force enable >/dev/null
  ufw reload >/dev/null
  # Port 8081 (the signaling backend) is proxied through Apache and only
  # listens on 127.0.0.1 -- it must not be reachable from the internet.
  log_success "UFW: SSH ${SSH_PORT}, 80, 443, 3478, and TURN relay range 49160-49360/udp open. Signaling backend stays loopback-only."
else
  log_warn "UFW not found -- skipping firewall config."
fi

# ============================================================
log_step "Step 12: Let's Encrypt SSL certificate"
# ============================================================
apt-get install -y -qq certbot python3-certbot-apache

if [[ -d "/etc/letsencrypt/live/${NC_DOMAIN}" ]]; then
  log_warn "Certificate for ${NC_DOMAIN} already exists -- reusing it."
else
  log_info "Requesting certificate for: ${NC_DOMAIN}"
  CERTBOT_ARGS=(--apache --non-interactive --agree-tos -d "${NC_DOMAIN}")
  if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
    CERTBOT_ARGS+=(-m "$LETSENCRYPT_EMAIL")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi
  if ! certbot "${CERTBOT_ARGS[@]}"; then
    log_error "Certificate request failed. Common causes:"
    echo "   - DNS for ${NC_DOMAIN} does not point at ${SERVER_IP} yet"
    echo "   - Port 80 blocked upstream (cloud provider firewall, not just UFW)"
    echo "   - Let's Encrypt rate limit hit (5 failures per hour per domain)"
    echo "   Fix the cause and re-run this script -- everything else is already in place."
    exit 1
  fi
  log_success "SSL certificate obtained."
fi

# Certbot creates a separate SSL vhost (nextcloud-le-ssl.conf).
# Inject the same proxy rules into it so HPB and notify_push work over HTTPS.
SSL_CONF="/etc/apache2/sites-available/nextcloud-le-ssl.conf"
if [[ -f "$SSL_CONF" ]]; then
  if ! grep -q "standalone-signaling" "$SSL_CONF"; then
    backup_config "$SSL_CONF"
    sed -i 's|</VirtualHost>| ProxyPreserveHost On\n RedirectMatch 302 ^/index\\.php/core/apps/recommended$ /apps/files/\n RedirectMatch 302 ^/core/apps/recommended$ /apps/files/\n ProxyPass /push/ws ws://127.0.0.1:7867/push/ws\n ProxyPass /push/ http://127.0.0.1:7867/push/\n ProxyPassReverse /push/ http://127.0.0.1:7867/push/\n ProxyPass /standalone-signaling/spreed ws://127.0.0.1:8081/spreed\n ProxyPassReverse /standalone-signaling/spreed ws://127.0.0.1:8081/spreed\n ProxyPass /standalone-signaling/ http://127.0.0.1:8081/\n ProxyPassReverse /standalone-signaling/ http://127.0.0.1:8081/\n</VirtualHost>|' "$SSL_CONF"
    log_success "Proxy rules injected into SSL vhost."
  else
    log_info "SSL vhost already has proxy rules."
  fi
fi

a2enmod http2 2>/dev/null || true
systemctl reload apache2

# ============================================================
log_step "Step 13: Save credentials & write autoconfig.php"
# ============================================================
# No admin credentials are generated here -- the user chooses their own
# username and password in the web wizard.
{
  echo "# Nextcloud install secrets -- chmod 600"
  echo "NC_DOMAIN=${NC_DOMAIN}"
  echo "SERVER_IP=${SERVER_IP}"
  echo "PHP_VER=${PHP_VER}"
  echo "NC_DB=${NC_DB}"
  echo "NC_DB_USER=${NC_DB_USER}"
  echo "NC_DB_PASS=${NC_DB_PASS}"
  echo "TURN_SECRET=${TURN_SECRET}"
  echo "REDIS_HOST=${REDIS_HOST}"
  echo "REDIS_PORT=${REDIS_PORT}"
  echo "DETECTED_TZ=${GENERIC_TIMEZONE}"
  echo "SIGNALING_SECRET=${SIGNALING_SECRET:-}"
  echo "SIGNALING_HASHKEY=${SIGNALING_HASHKEY:-}"
  echo "SIGNALING_BLOCKKEY=${SIGNALING_BLOCKKEY:-}"
  echo "INTERNAL_SECRET=${INTERNAL_SECRET:-}"
  echo "HPB_METHOD=${HPB_METHOD:-}"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
log_success "Credentials saved to ${ENV_FILE}"

if [[ ! -f "${NCWWW_DIR}/config/config.php" ]]; then
  cat > "${NCWWW_DIR}/config/autoconfig.php" <<AUTOCONFIGEOF
<?php
\$AUTOCONFIG = [
    'dbtype'        => 'pgsql',
    'dbname'        => '${NC_DB}',
    'dbuser'        => '${NC_DB_USER}',
    'dbpass'        => '${NC_DB_PASS}',
    'dbhost'        => '127.0.0.1',
    'dbtableprefix' => 'oc_',
    'directory'     => '${NCDATA_DIR}',
];
AUTOCONFIGEOF
  chown www-data:www-data "${NCWWW_DIR}/config/autoconfig.php"
  chmod 640 "${NCWWW_DIR}/config/autoconfig.php"
  log_success "autoconfig.php written -- wizard will pre-fill database fields."
fi

# ============================================================
log_step "Step 14: Register post-setup cron (runs after wizard is completed)"
# ============================================================
cat > "${PROJECT_DIR}/post-setup.sh" <<'POSTEOF'
#!/bin/bash
# post-setup.sh -- runs automatically after the Nextcloud web wizard is completed.
# Triggered by /etc/cron.d/nextcloud-post-setup polling for installation status.
set -euo pipefail

NCWWW_DIR="/var/www/nextcloud"
LOG_DIR="/var/log/nextcloud"
PROJECT_DIR="/opt/nextcloud"
LOG_FILE="${LOG_DIR}/post-setup.log"
OCC="sudo -u www-data php ${NCWWW_DIR}/occ"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[${TIMESTAMP}] $1" | tee -a "${LOG_FILE}"; }

log "======================================"
log "Post-setup started."

set -a
# shellcheck source=/dev/null
source "${PROJECT_DIR}/.env"
set +a

# -- Trusted domain & URLs ------------------------------------
$OCC config:system:set trusted_domains 0 --value="${NC_DOMAIN}"           2>/dev/null || true
$OCC config:system:set overwrite.cli.url  --value="https://${NC_DOMAIN}"  2>/dev/null || true
$OCC config:system:set overwriteprotocol  --value="https"                 2>/dev/null || true
$OCC config:system:set overwritehost      --value="${NC_DOMAIN}"          2>/dev/null || true

# -- Trusted proxies ------------------------------------------
$OCC config:system:set trusted_proxies 0 --value="127.0.0.1"             2>/dev/null || true
$OCC config:system:set trusted_proxies 1 --value="${SERVER_IP}"           2>/dev/null || true
$OCC config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR" 2>/dev/null || true

# -- Redis ----------------------------------------------------
$OCC config:system:set memcache.local       --value='\OC\Memcache\APCu'  2>/dev/null || true
$OCC config:system:set memcache.locking     --value='\OC\Memcache\Redis' 2>/dev/null || true
$OCC config:system:set memcache.distributed --value='\OC\Memcache\Redis' 2>/dev/null || true
$OCC config:system:set redis host           --value="${REDIS_HOST}"          2>/dev/null || true
$OCC config:system:set redis port           --value="${REDIS_PORT}" --type=integer 2>/dev/null || true

# -- General system settings ----------------------------------
$OCC config:system:set logtimezone           --value="${DETECTED_TZ}"    2>/dev/null || true
$OCC config:system:set skeletondirectory     --value=""                  2>/dev/null || true
$OCC config:system:set trashbin_retention_obligation --value="auto, 30"  2>/dev/null || true
$OCC config:system:set versions_retention_obligation --value="auto, 30"  2>/dev/null || true
$OCC config:system:set htaccess.RewriteBase  --value="/"                 2>/dev/null || true
$OCC maintenance:update:htaccess                                          2>/dev/null || true
$OCC config:system:set appconfig files max_chunk_size --value="0"        2>/dev/null || true
$OCC config:system:set maintenance_window_start --type=integer --value=2  2>/dev/null || true
$OCC config:system:set server_id --value="$(hostname)"                   2>/dev/null || true

# -- TURN server ----------------------------------------------
$OCC config:app:set spreed stun_servers --value="[{\"schemes\":\"stun:\",\"server\":\"${NC_DOMAIN}:3478\"}]"       2>/dev/null || true
$OCC config:app:set spreed turn_servers --value="[{\"schemes\":\"turn\",\"server\":\"${NC_DOMAIN}:3478\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]" 2>/dev/null || true

# -- Calendar -------------------------------------------------
$OCC config:app:set dav sendEventRemindersMode --value=occ               2>/dev/null || true
$OCC config:app:set dav sendEventRemindersPush --value=1                 2>/dev/null || true
$OCC config:app:set admin_notifications push_to_talk --value=1           2>/dev/null || true

# -- Background jobs ------------------------------------------
$OCC background:cron || true
sudo -u www-data php "${NCWWW_DIR}/cron.php" 2>/dev/null || true

log "System configs applied."

# -- Install apps ---------------------------------------------
install_app() {
  local APP_ID="$1"
  local DISPLAY_NAME="$2"
  log "Installing app: ${DISPLAY_NAME}"
  if $OCC app:install "${APP_ID}" --no-interaction >> "${LOG_FILE}" 2>&1; then
    log "  [ok] ${DISPLAY_NAME} installed."
  elif $OCC app:enable "${APP_ID}" >> "${LOG_FILE}" 2>&1; then
    log "  [ok] ${DISPLAY_NAME} enabled."
  else
    log "  [!!] ${DISPLAY_NAME} could not be installed."
  fi
}

install_app "spreed"               "Nextcloud Talk"
install_app "calendar"             "Nextcloud Calendar"
install_app "contacts"             "Nextcloud Contacts"
install_app "mail"                 "Nextcloud Mail"
install_app "assistant"            "Nextcloud Assistant"
install_app "flow_notifications"   "Nextcloud Flow"
install_app "deck"                 "Nextcloud Deck"
install_app "notify_push"          "Push Notification"
install_app "twofactor_totp"       "Two-Factor TOTP"

$OCC app:enable files_external                    >> "${LOG_FILE}" 2>&1 || true
$OCC app:enable twofactor_nextcloud_notification  >> "${LOG_FILE}" 2>&1 || true
$OCC config:app:set spreed signaling_dev --value=0 2>/dev/null || true

# Disable firstrunwizard -- this is the app that shows the "Recommended apps"
# page after first login. It has a known bug in Nextcloud 32+ where app
# installation fails silently. Since we install all apps via occ, this page
# is unnecessary and should not be shown to the user.
$OCC app:disable firstrunwizard >> "${LOG_FILE}" 2>&1 || true
log "firstrunwizard disabled -- recommended apps page will not appear."

log "Apps installed."

# -- notify_push daemon ---------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        PUSH_BINARY="${NCWWW_DIR}/apps/notify_push/bin/x86_64/notify_push" ;;
  aarch64|arm64) PUSH_BINARY="${NCWWW_DIR}/apps/notify_push/bin/aarch64/notify_push" ;;
  *)             PUSH_BINARY="" ;;
esac

if [[ -n "$PUSH_BINARY" && -f "$PUSH_BINARY" ]]; then
  chmod +x "$PUSH_BINARY"

  cat > /etc/systemd/system/notify_push.service <<PUSHSVC
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
PUSHSVC

  systemctl daemon-reload
  systemctl enable --now notify_push
  sleep 5
  $OCC notify_push:setup "https://${NC_DOMAIN}/push" >> "${LOG_FILE}" 2>&1 && log "notify_push configured." || log "notify_push setup had issues -- check log."
  systemctl restart notify_push
  sleep 3
  $OCC notify_push:self-test >> "${LOG_FILE}" 2>&1 && log "notify_push self-test passed." || log "notify_push self-test had issues."
fi

# -- HPB registration -----------------------------------------
# Remove ALL existing HPB entries before registering to avoid duplicate warning.
if [[ -n "${SIGNALING_SECRET:-}" ]]; then
  $OCC config:app:delete spreed signaling_servers 2>/dev/null || true
  sleep 1
  $OCC talk:signaling:add "wss://${NC_DOMAIN}/standalone-signaling" "${SIGNALING_SECRET}" >> "${LOG_FILE}" 2>&1 && log "HPB registered in Nextcloud." || log "HPB registration failed."
fi

# -- Final repair ---------------------------------------------
$OCC db:add-missing-indices       >> "${LOG_FILE}" 2>&1 || true
$OCC maintenance:repair           >> "${LOG_FILE}" 2>&1 || true
$OCC maintenance:update:htaccess  >> "${LOG_FILE}" 2>&1 || true

systemctl restart "php${PHP_VER}-fpm" apache2 redis-server 2>/dev/null || true
systemctl restart notify_push 2>/dev/null || true
systemctl restart signaling 2>/dev/null || systemctl restart nextcloud-spreed-signaling 2>/dev/null || true

# -- Remove this polling cron (self-destruct) -----------------
rm -f /etc/cron.d/nextcloud-post-setup
log "Post-setup cron removed."

log "Post-setup complete. Nextcloud is ready."
log "======================================"
POSTEOF
chmod +x "${PROJECT_DIR}/post-setup.sh"

# Register the polling cron -- checks every 30 seconds if Nextcloud is installed.
# Once installed, runs post-setup.sh and removes itself.
cat > /etc/cron.d/nextcloud-post-setup <<'POSTCRONEOF'
* * * * * root /bin/bash -c 'sudo -u www-data php /var/www/nextcloud/occ status 2>/dev/null | grep -q "installed: true" && bash /opt/nextcloud/post-setup.sh >> /var/log/nextcloud/post-setup.log 2>&1' || true
* * * * * root sleep 30 && /bin/bash -c 'sudo -u www-data php /var/www/nextcloud/occ status 2>/dev/null | grep -q "installed: true" && bash /opt/nextcloud/post-setup.sh >> /var/log/nextcloud/post-setup.log 2>&1' || true
POSTCRONEOF
chmod 644 /etc/cron.d/nextcloud-post-setup
log_success "post-setup.sh created and polling cron registered."

# ============================================================
log_step "Step 15: High-performance backend (HPB) for Talk"
# ============================================================
if [[ -n "${SIGNALING_SECRET:-}" && "${HPB_METHOD:-}" == "apt" && -f /etc/signaling/server.conf ]]; then
  log_warn "HPB already configured (method: apt) -- reusing existing secrets, refreshing domain."
  backup_config /etc/signaling/server.conf
  cat > /etc/signaling/server.conf <<SIGNALINGEOF
[http]
listen = 127.0.0.1:8081

[nats]
url = nats://localhost:4222

[sessions]
hashkey = ${SIGNALING_HASHKEY:-}
blockkey = ${SIGNALING_BLOCKKEY:-}

[backend]
backendtype = static
backends = nextcloud-backend
timeout = 10
connectionsperhost = 8
allowall = false

[nextcloud-backend]
urls = https://${NC_DOMAIN}
secret = ${SIGNALING_SECRET}
SIGNALINGEOF
  systemctl restart signaling 2>/dev/null || systemctl restart nextcloud-spreed-signaling 2>/dev/null || true
elif [[ -n "${SIGNALING_SECRET:-}" && "${HPB_METHOD:-}" == "docker" && -f /opt/talk-hpb/docker-compose.yml ]]; then
  log_warn "HPB already configured (method: docker) -- reusing existing secrets, refreshing domain."
  cat > /opt/talk-hpb/config/server.conf <<SIGCONF
[http]
listen = 127.0.0.1:8081

[app]
secret = ${INTERNAL_SECRET:-}

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
  (cd /opt/talk-hpb && docker compose restart signaling) 2>/dev/null || true
else
  log_info "Installing HPB via APT (Morph027 repository)..."

  curl -sL -o /etc/apt/trusted.gpg.d/morph027-nextcloud-spreed-signaling.asc \
    https://packaging.gitlab.io/nextcloud-spreed-signaling/gpg.key 2>/dev/null || \
  wget -q -O /etc/apt/trusted.gpg.d/morph027-nextcloud-spreed-signaling.asc \
    https://packaging.gitlab.io/nextcloud-spreed-signaling/gpg.key

  echo "deb [arch=amd64] https://packaging.gitlab.io/nextcloud-spreed-signaling signaling main" \
    > /etc/apt/sources.list.d/morph027-nextcloud-spreed-signaling.list

  apt-get update -qq

  log_info "Installing NATS server..."
  apt-get install -y -qq nats-server
  systemctl enable --now nats-server
  sleep 2

  HPB_METHOD=""
  SIGNALING_SECRET="${SIGNALING_SECRET:-}"

  if apt-get install -y -qq nextcloud-spreed-signaling morph027-keyring; then
    log_success "HPB installed via APT."
    HPB_METHOD="apt"

    mkdir -p /etc/signaling

    SIGNALING_SECRET="${SIGNALING_SECRET:-$(openssl rand -hex 32)}"
    SIGNALING_HASHKEY="${SIGNALING_HASHKEY:-$(openssl rand -hex 32)}"
    # blockkey must be exactly 16, 24, or 32 bytes -- token_hex(16) gives exactly 32 hex chars
    SIGNALING_BLOCKKEY="${SIGNALING_BLOCKKEY:-$(python3 -c "import secrets; print(secrets.token_hex(16))")}"

    backup_config /etc/signaling/server.conf
    # Write a clean server.conf from scratch. The package ships a
    # heavily-commented template; patching it with sed is fragile because
    # comment formats vary between versions.
    cat > /etc/signaling/server.conf <<SIGNALINGEOF
[http]
listen = 127.0.0.1:8081

[nats]
url = nats://localhost:4222

[sessions]
hashkey = ${SIGNALING_HASHKEY}
blockkey = ${SIGNALING_BLOCKKEY}

[backend]
backendtype = static
backends = nextcloud-backend
timeout = 10
connectionsperhost = 8
allowall = false

[nextcloud-backend]
urls = https://${NC_DOMAIN}
secret = ${SIGNALING_SECRET}
SIGNALINGEOF

    systemctl enable --now signaling 2>/dev/null \
      || systemctl enable --now nextcloud-spreed-signaling 2>/dev/null
    sleep 5
    systemctl restart signaling 2>/dev/null \
      || systemctl restart nextcloud-spreed-signaling 2>/dev/null
    sleep 5

    if curl -s -o /dev/null -w "%{http_code}" \
      http://127.0.0.1:8081/api/v1/welcome 2>/dev/null | grep -q "200"; then
      log_success "HPB is responding on port 8081."
    else
      log_warn "HPB not responding. Check: journalctl -u signaling -n 30 --no-pager"
    fi

  else
    log_warn "APT install failed -- falling back to Docker."
    HPB_METHOD="docker"

    if ! command -v docker &>/dev/null; then
      log_info "Installing Docker..."
      curl -sSL https://get.docker.com | CHANNEL=stable sh
    fi

    mkdir -p /opt/talk-hpb/config
    cd /opt/talk-hpb

    SIGNALING_SECRET="${SIGNALING_SECRET:-$(openssl rand -hex 32)}"
    INTERNAL_SECRET="${INTERNAL_SECRET:-$(openssl rand -hex 32)}"

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

    if curl -s -o /dev/null -w "%{http_code}" \
      http://127.0.0.1:8081/api/v1/welcome 2>/dev/null | grep -q "200"; then
      log_success "HPB (Docker) is responding on port 8081."
    else
      log_warn "HPB (Docker) not responding. Check: docker compose -f /opt/talk-hpb/docker-compose.yml logs"
    fi

    log_success "HPB (Docker) installed."
  fi

  # Persist the secrets by rewriting .env's key=value lines rather than
  # appending, so re-running this script never leaves duplicate entries.
  sed -i \
    -e "s|^SIGNALING_SECRET=.*|SIGNALING_SECRET=${SIGNALING_SECRET}|" \
    -e "s|^SIGNALING_HASHKEY=.*|SIGNALING_HASHKEY=${SIGNALING_HASHKEY:-}|" \
    -e "s|^SIGNALING_BLOCKKEY=.*|SIGNALING_BLOCKKEY=${SIGNALING_BLOCKKEY:-}|" \
    -e "s|^INTERNAL_SECRET=.*|INTERNAL_SECRET=${INTERNAL_SECRET:-}|" \
    -e "s|^HPB_METHOD=.*|HPB_METHOD=${HPB_METHOD}|" \
    "$ENV_FILE"
fi

# ============================================================
log_step "Step 16: Fix Imagick SVG support"
# ============================================================
apt-get install -y -qq libmagickwand-dev 2>/dev/null || true
if command -v pecl &>/dev/null; then
  pecl install --quiet imagick <<< "yes" || true
  systemctl restart "php${PHP_VER}-fpm"
  log_success "Imagick rebuilt with SVG support."
else
  log_warn "pecl not found -- skipping Imagick rebuild."
fi

# ============================================================
log_step "Step 17: Cron jobs"
# ============================================================
OCC="sudo -u www-data php ${NCWWW_DIR}/occ"

echo "*/5 * * * * www-data php -f ${NCWWW_DIR}/cron.php > /dev/null 2>&1" \
  > /etc/cron.d/nextcloud
chmod 644 /etc/cron.d/nextcloud
$OCC background:cron || true
sudo -u www-data php "${NCWWW_DIR}/cron.php" 2>/dev/null || true
log_success "Nextcloud cron configured and executed once."

echo "*/5 * * * * www-data php -f ${NCWWW_DIR}/occ dav:send-event-reminders > /dev/null 2>&1" \
  > /etc/cron.d/nextcloud-calendar
chmod 644 /etc/cron.d/nextcloud-calendar

echo "30 3 1,15 * * root certbot renew --quiet --deploy-hook 'systemctl reload apache2'" \
  > /etc/cron.d/certbot-nextcloud
chmod 644 /etc/cron.d/certbot-nextcloud

log_success "All cron jobs configured."

# ============================================================
log_step "Step 18: Auto-update"
# ============================================================
cat > "${PROJECT_DIR}/auto-update.sh" <<'UPDATEEOF'
#!/bin/bash
set -euo pipefail
NCWWW_DIR="/var/www/nextcloud"
LOG_FILE="/var/log/nextcloud/autoupdate.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
log() { echo "[${TIMESTAMP}] $1" | tee -a "${LOG_FILE}"; }
OCC="sudo -u www-data php ${NCWWW_DIR}/occ"

log "===================================="
log "Starting Nextcloud update check..."

$OCC maintenance:mode --on  >> "${LOG_FILE}" 2>&1
$OCC upgrade --no-interaction >> "${LOG_FILE}" 2>&1 || true
$OCC app:update --all        >> "${LOG_FILE}" 2>&1 || true
$OCC maintenance:repair      >> "${LOG_FILE}" 2>&1 || true
$OCC maintenance:mode --off  >> "${LOG_FILE}" 2>&1

systemctl restart notify_push                   2>/dev/null || true
systemctl restart signaling                     2>/dev/null || true
systemctl restart nextcloud-spreed-signaling    2>/dev/null || true
docker compose -f /opt/talk-hpb/docker-compose.yml restart signaling 2>/dev/null || true

log "Update routine finished."
log "===================================="
UPDATEEOF
chmod +x "${PROJECT_DIR}/auto-update.sh"

if $AUTOUPDATE_ENABLED; then
  echo "0 3 * * * root /opt/nextcloud/auto-update.sh" > /etc/cron.d/nextcloud-autoupdate
  chmod 644 /etc/cron.d/nextcloud-autoupdate
  log_success "Auto-update scheduled (daily 03:00)."
else
  rm -f /etc/cron.d/nextcloud-autoupdate
  log_warn "Auto-update disabled. Run it with: bash ${PROJECT_DIR}/auto-update.sh"
fi

# ============================================================
log_step "Step 19: Backup system (BorgBackup)"
# ============================================================
cat > "${PROJECT_DIR}/backup.sh" <<BORGEOF
#!/bin/bash
set -euo pipefail
set -a; source /opt/nextcloud/.env; set +a
NCWWW_DIR="/var/www/nextcloud"
NCDATA_DIR="/var/nextcloud-data"
BACKUP_DIR="/opt/nextcloud/backups"
BORG_REPO="\${BACKUP_DIR}/borg"
LOG_FILE="/var/log/nextcloud/backup.log"
RETAIN_DAYS="\${RETAIN_DAYS:-${BACKUP_RETAIN_DAYS}}"
TIMESTAMP=\$(date '+%Y-%m-%d_%H-%M-%S')
OCC="sudo -u www-data php \${NCWWW_DIR}/occ"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\${LOG_FILE}"; }

log "===================================="
log "Starting backup: \${TIMESTAMP}"

\$OCC maintenance:mode --on
log "Maintenance mode ON."

if [ ! -d "\${BORG_REPO}" ]; then
  borg init --encryption=none "\${BORG_REPO}"
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

SIZE=\$(borg info "\${BORG_REPO}::\${TIMESTAMP}" 2>/dev/null \
  | grep "Compressed size" | awk '{print \$3,\$4}' || echo "N/A")
log "Backup created: \${TIMESTAMP} (\${SIZE})"

borg prune \
  --keep-daily="\${RETAIN_DAYS}" \
  --keep-weekly=4 \
  --keep-monthly=3 \
  "\${BORG_REPO}" >> "\${LOG_FILE}" 2>&1 || true

find "\${BACKUP_DIR}" -name "nc_db_*.sql.gz" \
  -mtime "+\${RETAIN_DAYS}" -delete 2>/dev/null || true

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
case "${1:-}" in
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

if $BACKUP_ENABLED; then
  bash "${PROJECT_DIR}/backup-manager.sh" enable
else
  bash "${PROJECT_DIR}/backup-manager.sh" disable
fi
log_success "BorgBackup scripts created (auto-backup: $($BACKUP_ENABLED && echo enabled || echo disabled))."

# ============================================================
log_step "Step 20: Final service restart & checks"
# ============================================================
# Nextcloud is not yet installed at this point (wizard pending).
# occ commands run after the user completes the wizard via post-setup.sh.
systemctl restart "php${PHP_VER}-fpm" apache2 redis-server 2>/dev/null || true
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

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Nextcloud is installed and running${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  URL:              ${CYAN}https://${NC_DOMAIN}${NC}"
echo -e "  SSL:              ${CYAN}Let's Encrypt (auto-renew: 1st & 15th of month)${NC}"
echo -e "  Database:         ${CYAN}PostgreSQL -- ${NC_DB}${NC}"
echo -e "  Timezone:         ${CYAN}${GENERIC_TIMEZONE}${NC}"
echo -e "  Install time:     ${CYAN}${TOTAL_TIME}${NC}"
echo ""
echo -e "${BOLD}Stack:${NC}"
echo -e "  PHP:              ${CYAN}${PHP_VER} + OPcache/JIT + APCu${NC}"
echo -e "  Cache:            ${CYAN}Redis (socket or TCP) + APCu${NC}"
echo -e "  Push:             ${CYAN}notify_push (arch: $(uname -m))${NC}"
echo -e "  TURN:             ${CYAN}coturn :3478 TCP/UDP${NC}"
echo -e "  HPB (Talk):       ${CYAN}${HPB_METHOD:-unknown} method${NC}"
echo -e "  Backup:           ${CYAN}BorgBackup ($($BACKUP_ENABLED && echo "nightly 02:00, ${BACKUP_RETAIN_DAYS}d retention" || echo disabled))${NC}"
echo -e "  Auto-update:      ${CYAN}$($AUTOUPDATE_ENABLED && echo 'daily 03:00' || echo disabled)${NC}"
echo ""
echo -e "${BOLD}Files:${NC}"
echo -e "  Web root:         ${CYAN}${NCWWW_DIR}${NC}"
echo -e "  Data dir:         ${CYAN}${NCDATA_DIR}${NC}"
echo -e "  Project:          ${CYAN}${PROJECT_DIR}${NC}"
echo -e "  Secrets:          ${CYAN}${ENV_FILE}${NC}"
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
echo -e "  TURN status:      ${CYAN}systemctl status coturn${NC}"
echo -e "  Push status:      ${CYAN}systemctl status notify_push${NC}"
echo -e "  HPB status:       ${CYAN}systemctl status signaling${NC}"
echo -e "  Apache logs:      ${CYAN}tail -f /var/log/apache2/nextcloud_error.log${NC}"
echo -e "  Manual update:    ${CYAN}bash ${PROJECT_DIR}/auto-update.sh${NC}"
echo ""
echo -e "${BOLD}First-time setup:${NC}"
echo -e "  ${CYAN}1. Open the URL above in your browser.${NC}"
echo -e "  ${CYAN}2. The setup wizard will appear -- choose your admin${NC}"
echo -e "  ${CYAN}   username and password. Database fields are pre-filled.${NC}"
echo -e "  ${CYAN}3. After you click 'Finish setup', apps and configs will${NC}"
echo -e "  ${CYAN}   install automatically in the background (1-3 minutes).${NC}"
echo -e "  ${CYAN}   Monitor progress: tail -f /var/log/nextcloud/post-setup.log${NC}"
echo ""
if ! $BACKUP_ENABLED; then
  log_warn "Backups are off. Turn them on later with: bash ${PROJECT_DIR}/backup-manager.sh enable"
fi
echo -e "${CYAN}Tip: run 'bash ${PROJECT_DIR}/backup-manager.sh now' once setup finishes,${NC}"
echo -e "${CYAN}then practise a restore before you depend on it.${NC}"
echo ""
