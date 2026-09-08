#!/usr/bin/env bash
#
# Interactive first-boot setup for a fresh Ubuntu server.
# Updates, a sudo user with key-only SSH, firewall, fail2ban, automatic
# security updates, swap and sensible kernel settings.
#
# Usage:  sudo bash bootstrap-server.sh
# Re-running is safe: existing users, keys and rules are left alone.
#
set -euo pipefail

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

trap 'log_error "Failed at line $LINENO."' ERR

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ROOT="/root/bootstrap-backups/${STAMP}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"

# ------------------------------------------------------------------
log_step "Step 0: Preflight"
# ------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"
[[ -t 0 ]] || die "This script is interactive. Download it first, then run it."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  log_info "System: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] \
    || log_warn "Written for Ubuntu/Debian. Proceed with care."
fi

CURRENT_SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
log_info "Current SSH port: ${CURRENT_SSH_PORT}"
log_info "Logged in as: $(who am i 2>/dev/null | awk '{print $1}' || echo root)"

mkdir -p "$BACKUP_ROOT"
log_success "Config backups will go to ${BACKUP_ROOT}"

# ------------------------------------------------------------------
log_step "Step 1: Questions"
# ------------------------------------------------------------------

# --- Identity ------------------------------------------------------
NEW_HOSTNAME=$(ask "Hostname" "$(hostname)")
DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
NEW_TZ=$(ask "Timezone" "$DETECTED_TZ")

# --- Admin user ----------------------------------------------------
echo ""
echo "  Working as root over SSH is the single most common way servers get"
echo "  compromised. A normal user with sudo is the standard alternative."
CREATE_USER=false
ADMIN_USER=""
if ask_yn "Create (or configure) a sudo user?" "y"; then
  CREATE_USER=true
  while true; do
    ADMIN_USER=$(ask "Username")
    if [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      break
    fi
    log_warn "Invalid username. Lowercase letters, digits, - and _ only."
  done
fi

# --- SSH key -------------------------------------------------------
SSH_PUBKEY=""
ROOT_KEYS="/root/.ssh/authorized_keys"
if $CREATE_USER; then
  echo ""
  if [[ -s "$ROOT_KEYS" ]]; then
    log_info "Found $(grep -c '^ssh-\|^ecdsa-' "$ROOT_KEYS" || echo 0) key(s) in root's authorized_keys."
    if ask_yn "Copy root's authorized keys to ${ADMIN_USER}?" "y"; then
      SSH_PUBKEY="COPY_FROM_ROOT"
    fi
  fi
  if [[ -z "$SSH_PUBKEY" ]]; then
    echo "  Paste the public key for ${ADMIN_USER} (the contents of your"
    echo "  ~/.ssh/id_ed25519.pub, one line), or leave empty to skip."
    read -rp "$(echo -e "${BOLD}?${NC} Public key: ")" SSH_PUBKEY
    if [[ -n "$SSH_PUBKEY" && ! "$SSH_PUBKEY" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-) ]]; then
      die "That does not look like an SSH public key. Aborting before anything changed."
    fi
  fi
fi

# --- SSH hardening -------------------------------------------------
echo ""
HARDEN_SSH=false
DISABLE_PW=false
DISABLE_ROOT=false
NEW_SSH_PORT="$CURRENT_SSH_PORT"

if ask_yn "Harden the SSH server?" "y"; then
  HARDEN_SSH=true

  echo ""
  echo "  Key-only login removes password brute-forcing entirely. It also locks"
  echo "  you out permanently if your key is not working, so the script verifies"
  echo "  a key is in place first and sets a 10-minute automatic rollback."
  if [[ -n "$SSH_PUBKEY" ]] || [[ -s "$ROOT_KEYS" ]]; then
    if ask_yn "Disable password authentication (key-only)?" "y"; then DISABLE_PW=true; fi
  else
    log_warn "No SSH key available — password login must stay enabled."
  fi

  if $CREATE_USER && [[ -n "$SSH_PUBKEY" ]]; then
    if ask_yn "Disable direct root login over SSH?" "y"; then DISABLE_ROOT=true; fi
  else
    log_warn "Root login stays enabled — there is no other way in yet."
  fi

  echo ""
  echo "  Moving off port 22 cuts automated scanner noise. It is not real"
  echo "  security, and it means every future connection needs -p."
  if ask_yn "Change the SSH port?" "n"; then
    while true; do
      NEW_SSH_PORT=$(ask "New SSH port" "2222")
      if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && (( NEW_SSH_PORT > 0 && NEW_SSH_PORT < 65536 )); then
        if ss -tlnp 2>/dev/null | grep -q ":${NEW_SSH_PORT} " && [[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
          log_warn "Port ${NEW_SSH_PORT} is already in use."
        else
          break
        fi
      else
        log_warn "Enter a number between 1 and 65535."
      fi
    done
  fi
fi

# --- Firewall ------------------------------------------------------
echo ""
OPEN_WEB=false
if ask_yn "Open ports 80 and 443 (web server / reverse proxy)?" "y"; then OPEN_WEB=true; fi
EXTRA_PORTS=$(ask "Any other ports to open, comma separated (blank for none)" "")

# --- Services ------------------------------------------------------
echo ""
INSTALL_FAIL2BAN=true
ask_yn "Install fail2ban (bans repeated failed logins)?" "y" || INSTALL_FAIL2BAN=false

AUTO_UPDATES=true
ask_yn "Enable automatic security updates?" "y" || AUTO_UPDATES=false
AUTO_REBOOT=false
if $AUTO_UPDATES; then
  echo "  Kernel updates only take effect after a reboot. Automatic reboots"
  echo "  keep you patched but will interrupt whatever is running."
  if ask_yn "Reboot automatically at 04:00 when an update requires it?" "n"; then AUTO_REBOOT=true; fi
fi

# --- Swap ----------------------------------------------------------
TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CURRENT_SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
SETUP_SWAP=false
SWAP_SIZE_GB=2
echo ""
log_info "RAM: ${TOTAL_MEM_MB} MB, swap: ${CURRENT_SWAP_MB} MB"
if (( CURRENT_SWAP_MB < 100 )); then
  if ask_yn "Create a swap file?" "y"; then
    SETUP_SWAP=true
    (( TOTAL_MEM_MB < 2048 )) && SWAP_SIZE_GB=2 || SWAP_SIZE_GB=4
    SWAP_SIZE_GB=$(ask "Swap size in GB" "$SWAP_SIZE_GB")
  fi
fi

# --- Confirm -------------------------------------------------------
echo ""
echo -e "${BOLD}Summary${NC}"
echo "  Hostname:        ${NEW_HOSTNAME}"
echo "  Timezone:        ${NEW_TZ}"
echo "  System upgrade:  yes (apt full-upgrade)"
echo "  Sudo user:       $($CREATE_USER && echo "${ADMIN_USER}" || echo 'none')"
echo "  SSH port:        ${NEW_SSH_PORT}$([[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]] && echo " (changed from ${CURRENT_SSH_PORT})")"
echo "  Password login:  $($DISABLE_PW && echo 'disabled (key only)' || echo 'enabled')"
echo "  Root SSH login:  $($DISABLE_ROOT && echo 'disabled' || echo 'enabled')"
echo "  Firewall:        UFW, SSH${OPEN_WEB:+ + 80/443}${EXTRA_PORTS:+ + ${EXTRA_PORTS}}"
echo "  fail2ban:        $($INSTALL_FAIL2BAN && echo yes || echo no)"
echo "  Auto updates:    $($AUTO_UPDATES && echo "yes$($AUTO_REBOOT && echo ', reboot at 04:00')" || echo no)"
echo "  Swap:            $($SETUP_SWAP && echo "${SWAP_SIZE_GB} GB" || echo 'unchanged')"
echo ""
ask_yn "Apply all of this?" "y" || die "Aborted. Nothing was changed."

# ------------------------------------------------------------------
log_step "Step 2: System update"
# ------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log_info "Updating package lists..."
apt-get update -qq
log_info "Upgrading packages (this can take several minutes)..."
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
apt-get -y -qq autoremove
log_success "System up to date."

# ------------------------------------------------------------------
log_step "Step 3: Base packages"
# ------------------------------------------------------------------
PACKAGES=(ca-certificates curl wget gnupg lsb-release apt-transport-https
          ufw git vim nano htop ncdu tmux rsync unzip zip jq
          net-tools dnsutils bash-completion software-properties-common)
if $INSTALL_FAIL2BAN; then PACKAGES+=(fail2ban); fi
if $AUTO_UPDATES; then PACKAGES+=(unattended-upgrades apt-listchanges); fi

apt-get install -y -qq "${PACKAGES[@]}"
log_success "Base packages installed."

# ------------------------------------------------------------------
log_step "Step 4: Hostname and timezone"
# ------------------------------------------------------------------
if [[ "$NEW_HOSTNAME" != "$(hostname)" ]]; then
  cp /etc/hosts "${BACKUP_ROOT}/hosts"
  hostnamectl set-hostname "$NEW_HOSTNAME"
  # Keep /etc/hosts consistent, or sudo warns on every invocation.
  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
  fi
  log_success "Hostname set to ${NEW_HOSTNAME}."
fi

timedatectl set-timezone "$NEW_TZ"
timedatectl set-ntp true 2>/dev/null || true
log_success "Timezone set to ${NEW_TZ}, time sync on."

# ------------------------------------------------------------------
log_step "Step 5: Swap"
# ------------------------------------------------------------------
if $SETUP_SWAP; then
  if [[ -f /swapfile ]]; then
    log_warn "/swapfile already exists — leaving it alone."
  else
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Prefer RAM, but use swap before the OOM killer starts picking victims.
    sysctl -qw vm.swappiness=10
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    log_success "${SWAP_SIZE_GB} GB swap active (swappiness 10)."
  fi
else
  log_info "Swap unchanged."
fi

# ------------------------------------------------------------------
log_step "Step 6: Admin user"
# ------------------------------------------------------------------
if $CREATE_USER; then
  if id "$ADMIN_USER" &>/dev/null; then
    log_warn "User ${ADMIN_USER} already exists — keeping it."
  else
    adduser --disabled-password --gecos "" "$ADMIN_USER" >/dev/null
    log_success "User ${ADMIN_USER} created."
    if ! $DISABLE_PW; then
      echo "  Password auth is staying on, so ${ADMIN_USER} needs a password."
      passwd "$ADMIN_USER"
    fi
  fi

  usermod -aG sudo "$ADMIN_USER"
  log_success "${ADMIN_USER} added to the sudo group."

  USER_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "${USER_HOME}/.ssh"
  AUTH_FILE="${USER_HOME}/.ssh/authorized_keys"
  touch "$AUTH_FILE"

  if [[ "$SSH_PUBKEY" == "COPY_FROM_ROOT" ]]; then
    while read -r key; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      grep -qxF "$key" "$AUTH_FILE" || echo "$key" >> "$AUTH_FILE"
    done < "$ROOT_KEYS"
    log_success "Root's keys copied to ${ADMIN_USER}."
  elif [[ -n "$SSH_PUBKEY" ]]; then
    grep -qxF "$SSH_PUBKEY" "$AUTH_FILE" || echo "$SSH_PUBKEY" >> "$AUTH_FILE"
    log_success "Public key installed for ${ADMIN_USER}."
  fi

  chmod 600 "$AUTH_FILE"
  chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_FILE"
  KEY_COUNT=$(grep -cE '^(ssh-|ecdsa-)' "$AUTH_FILE" || true)
  log_info "${ADMIN_USER} has ${KEY_COUNT} authorized key(s)."

  if $DISABLE_PW && (( KEY_COUNT == 0 )); then
    die "Refusing to disable password login: ${ADMIN_USER} has no keys. Nothing was changed to SSH yet."
  fi
fi

# ------------------------------------------------------------------
log_step "Step 7: Firewall"
# ------------------------------------------------------------------
# SSH is allowed BEFORE enabling, otherwise enabling drops your session.
ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH' >/dev/null
if [[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
  ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH (old, remove after testing)' >/dev/null
fi

if $OPEN_WEB; then
  ufw allow 80/tcp  comment 'HTTP'  >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
fi

if [[ -n "$EXTRA_PORTS" ]]; then
  IFS=',' read -ra PORTS <<< "$EXTRA_PORTS"
  for p in "${PORTS[@]}"; do
    p="${p// /}"
    if [[ "$p" =~ ^[0-9]+$ ]]; then
      ufw allow "${p}/tcp" >/dev/null
      log_info "Opened port ${p}."
    fi
  done
fi

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
log_success "UFW active."
ufw status numbered | sed 's/^/        /'

# ------------------------------------------------------------------
log_step "Step 8: SSH hardening"
# ------------------------------------------------------------------
if $HARDEN_SSH; then
  cp -r /etc/ssh "${BACKUP_ROOT}/ssh"
  log_success "SSH config backed up."

  mkdir -p /etc/ssh/sshd_config.d
  {
    echo "# Written by bootstrap-server.sh on $(date -Iseconds)"
    echo "Port ${NEW_SSH_PORT}"
    echo "PermitRootLogin $($DISABLE_ROOT && echo 'no' || echo 'prohibit-password')"
    echo "PasswordAuthentication $($DISABLE_PW && echo 'no' || echo 'yes')"
    echo "KbdInteractiveAuthentication no"
    echo "PubkeyAuthentication yes"
    echo "PermitEmptyPasswords no"
    echo "X11Forwarding no"
    echo "MaxAuthTries 4"
    echo "LoginGraceTime 30"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    if $CREATE_USER; then
      echo "AllowUsers ${ADMIN_USER}$($DISABLE_ROOT || echo ' root')"
    fi
  } > "$SSHD_DROPIN"

  # Ubuntu 24.04+ activates sshd through a socket unit, where sshd_config's
  # Port directive is ignored. The listener has to be changed on the socket.
  SOCKET_ACTIVATED=false
  if systemctl is-enabled ssh.socket &>/dev/null; then
    SOCKET_ACTIVATED=true
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<SOCKEOF
[Socket]
ListenStream=
ListenStream=${NEW_SSH_PORT}
SOCKEOF
    systemctl daemon-reload
    log_info "Socket-activated sshd detected — port set on ssh.socket."
  fi

  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    die "sshd rejected the new configuration. It was removed; SSH is untouched."
  fi
  log_success "sshd configuration validated."

  # Safety net: put the old config back automatically unless confirmed.
  cat > /usr/local/sbin/ssh-rollback <<ROLLEOF
#!/bin/bash
# Restores the pre-hardening SSH configuration.
rm -rf /etc/ssh
cp -r "${BACKUP_ROOT}/ssh" /etc/ssh
rm -f /etc/systemd/system/ssh.socket.d/override.conf
systemctl daemon-reload
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh
logger -t ssh-rollback "SSH configuration rolled back by the bootstrap safety net."
ROLLEOF
  chmod +x /usr/local/sbin/ssh-rollback

  cat > /usr/local/bin/ssh-confirm <<'CONFIRMEOF'
#!/bin/bash
# Cancels the pending SSH rollback once you have confirmed you can still log in.
if systemctl stop ssh-rollback.timer 2>/dev/null; then
  systemctl reset-failed ssh-rollback.timer 2>/dev/null || true
  echo "Rollback cancelled. The hardened SSH configuration is now permanent."
else
  echo "No pending rollback found — nothing to cancel."
fi
CONFIRMEOF
  chmod +x /usr/local/bin/ssh-confirm

  systemd-run --unit=ssh-rollback --on-active=10min /usr/local/sbin/ssh-rollback >/dev/null 2>&1 \
    && log_success "Rollback armed: SSH reverts in 10 minutes unless you run ssh-confirm." \
    || log_warn "Could not arm the rollback timer — test your login carefully."

  if $SOCKET_ACTIVATED; then systemctl restart ssh.socket; fi
  systemctl restart ssh
  log_success "SSH restarted on port ${NEW_SSH_PORT}."
else
  log_info "SSH left as-is."
fi

# ------------------------------------------------------------------
log_step "Step 9: fail2ban"
# ------------------------------------------------------------------
if $INSTALL_FAIL2BAN; then
  cat > /etc/fail2ban/jail.local <<F2BEOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
destemail = root@localhost

[sshd]
enabled = true
port    = ${NEW_SSH_PORT}
maxretry = 4
bantime  = 2h
F2BEOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  log_success "fail2ban active (4 tries, 2 hour ban on SSH)."
else
  log_info "fail2ban skipped."
fi

# ------------------------------------------------------------------
log_step "Step 10: Automatic security updates"
# ------------------------------------------------------------------
if $AUTO_UPDATES; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

  cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<AUEOF
// Security updates only — feature updates stay manual.
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$($AUTO_REBOOT && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
AUEOF

  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  log_success "Security updates applied automatically$($AUTO_REBOOT && echo ', reboot at 04:00 when needed')."
else
  log_info "Automatic updates skipped. Run apt update && apt upgrade yourself."
fi

# ------------------------------------------------------------------
log_step "Step 11: Kernel and logging settings"
# ------------------------------------------------------------------
cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTLEOF'
# Network
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0

# Kernel
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Higher limits for servers running many connections
fs.file-max = 65535
net.core.somaxconn = 1024
SYSCTLEOF
sysctl -q --system >/dev/null 2>&1 || true
log_success "Kernel settings applied."

# Journals default to unbounded growth on some images.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-size.conf <<'JEOF'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
JEOF
systemctl restart systemd-journald
log_success "Journal capped at 500 MB / 1 month."

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
SERVER_IP=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

cat > /root/bootstrap-summary.txt <<SUMEOF
Server bootstrap — $(date -Iseconds)

Hostname:       ${NEW_HOSTNAME}
IP:             ${SERVER_IP}
Timezone:       ${NEW_TZ}
SSH port:       ${NEW_SSH_PORT}
Admin user:     $($CREATE_USER && echo "${ADMIN_USER}" || echo 'none created')
Password login: $($DISABLE_PW && echo 'disabled' || echo 'enabled')
Root SSH:       $($DISABLE_ROOT && echo 'disabled' || echo 'enabled')
fail2ban:       $($INSTALL_FAIL2BAN && echo active || echo 'not installed')
Auto updates:   $($AUTO_UPDATES && echo enabled || echo disabled)
Config backups: ${BACKUP_ROOT}
SUMEOF
chmod 600 /root/bootstrap-summary.txt

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Server ready${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""

if $HARDEN_SSH; then
  echo -e "${BOLD}${RED}  DO NOT CLOSE THIS SESSION YET.${NC}"
  echo ""
  echo -e "  Open a ${BOLD}second terminal${NC} and confirm you can log in:"
  echo ""
  if $CREATE_USER; then
    echo -e "      ${CYAN}ssh -p ${NEW_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${NC}"
  else
    echo -e "      ${CYAN}ssh -p ${NEW_SSH_PORT} root@${SERVER_IP}${NC}"
  fi
  echo ""
  echo -e "  ${BOLD}If it works${NC}, lock the changes in from that new session:"
  echo -e "      ${CYAN}sudo ssh-confirm${NC}"
  echo ""
  echo -e "  ${BOLD}If it does not${NC}, change nothing and wait. In 10 minutes the old"
  echo -e "  SSH configuration comes back on its own and this session keeps working."
  echo ""
fi

echo -e "${BOLD}Details${NC}"
echo -e "  Summary file:  ${CYAN}/root/bootstrap-summary.txt${NC}"
echo -e "  Config backup: ${CYAN}${BACKUP_ROOT}${NC}"
echo -e "  Firewall:      ${CYAN}ufw status numbered${NC}"
if $INSTALL_FAIL2BAN; then echo -e "  Bans:          ${CYAN}fail2ban-client status sshd${NC}"; fi
echo ""

if [[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
  log_warn "Port ${CURRENT_SSH_PORT} is still open as a fallback."
  echo -e "  Close it once the new port is confirmed: ${CYAN}ufw delete allow ${CURRENT_SSH_PORT}/tcp${NC}"
  echo ""
fi

if [[ -f /var/run/reboot-required ]]; then
  log_warn "A reboot is required to finish applying kernel updates."
  echo -e "  Do it ${BOLD}after${NC} confirming SSH access: ${CYAN}reboot${NC}"
  echo ""
fi
