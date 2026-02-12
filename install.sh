#!/usr/bin/env bash
# install.sh - Install docker-backup on the backup server (pull model)
set -euo pipefail

INSTALL_DIR="/opt/docker-backup"
SYSTEMD_DIR="/etc/systemd/system"
OPENRC_DIR="/etc/init.d"
CRON_FILE="/etc/crontabs/root"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# --- Detect distro ---
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            alpine)  echo "alpine" ;;
            arch|endeavouros|manjaro) echo "arch" ;;
            debian|ubuntu|raspbian|linuxmint|pop) echo "debian" ;;
            fedora|rhel|centos|rocky|alma) echo "fedora" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"
INIT_SYSTEM="$(detect_init)"

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

bold "=== Docker Backup Installer (Backup Server) ==="
echo ""

# --- Check dependencies ---
info "Checking dependencies..."
info "Detected distro: $DISTRO, init: $INIT_SYSTEM"

missing=()
for cmd in bash age zstd rsync jq curl ssh tar; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing dependencies: ${missing[*]}"
    echo "  Install them with your package manager, e.g.:"
    case "$DISTRO" in
        alpine)
            echo "    apk add bash age zstd rsync jq curl openssh-client tar" ;;
        arch)
            echo "    pacman -S ${missing[*]}" ;;
        debian)
            echo "    apt install ${missing[*]}" ;;
        fedora)
            echo "    dnf install ${missing[*]}" ;;
        *)
            echo "    <your-package-manager> install ${missing[*]}" ;;
    esac
    exit 1
fi
info "All dependencies found"

# --- Generate age keypair if needed ---
AGE_DIR="/root/.age"
AGE_KEY_FILE="$AGE_DIR/backup.key"

if [[ ! -f "$AGE_KEY_FILE" ]]; then
    info "Generating age keypair..."
    mkdir -p "$AGE_DIR"
    chmod 700 "$AGE_DIR"
    age-keygen -o "$AGE_KEY_FILE" 2>/tmp/age_keygen_out
    chmod 600 "$AGE_KEY_FILE"

    AGE_PUBLIC_KEY="$(grep '^# public key:' /tmp/age_keygen_out | sed 's/# public key: //')"
    if [[ -z "$AGE_PUBLIC_KEY" ]]; then
        AGE_PUBLIC_KEY="$(grep '^# public key:' "$AGE_KEY_FILE" | sed 's/# public key: //')"
    fi
    rm -f /tmp/age_keygen_out

    info "Age private key: $AGE_KEY_FILE"
    bold "Age public key:  $AGE_PUBLIC_KEY"
    echo ""
    warn "IMPORTANT: Back up $AGE_KEY_FILE securely! Without it, backups cannot be decrypted."
    echo ""
else
    info "Age keypair already exists: $AGE_KEY_FILE"
    AGE_PUBLIC_KEY="$(grep '^# public key:' "$AGE_KEY_FILE" | sed 's/# public key: //')"
fi

# --- Generate SSH key for backups ---
SSH_KEY="/root/.ssh/backup_ed25519"

if [[ ! -f "$SSH_KEY" ]]; then
    info "Generating SSH key for backups..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "docker-backup@$(hostname)" >/dev/null 2>&1
    chmod 600 "$SSH_KEY"
    info "SSH key generated: $SSH_KEY"
    echo ""
    bold "Add this public key to the PRODUCTION server's ~/.ssh/authorized_keys:"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
else
    info "SSH key already exists: $SSH_KEY"
fi

# --- Collect configuration ---
echo ""
bold "=== Configuration ==="
echo ""

CONFIG_FILE="$INSTALL_DIR/docker-backup.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    warn "Existing config found: $CONFIG_FILE"
    read -rp "Overwrite? [y/N] " overwrite
    if [[ ! "$overwrite" =~ ^[Yy] ]]; then
        info "Keeping existing config"
        SKIP_CONFIG=true
    else
        SKIP_CONFIG=false
    fi
else
    SKIP_CONFIG=false
fi

if [[ "$SKIP_CONFIG" == "false" ]]; then
    read -rp "Production server host: " production_host
    read -rp "Production server user [root]: " production_user
    production_user="${production_user:-root}"
    read -rp "Production SSH port [22]: " production_port
    production_port="${production_port:-22}"
    read -rp "Docker source directory on production [/opt/docker]: " production_source_dir
    production_source_dir="${production_source_dir:-/opt/docker}"

    read -rp "Local backup directory [/backups/$(hostname -s)]: " backup_dir
    backup_dir="${backup_dir:-/backups/$(hostname -s)}"

    read -rp "Webhook URL (leave empty to skip): " webhook_url
    webhook_type="discord"
    telegram_chat_id=""
    if [[ -n "$webhook_url" ]]; then
        read -rp "Webhook type [discord/slack/telegram]: " webhook_type
        webhook_type="${webhook_type:-discord}"
        if [[ "$webhook_type" == "telegram" ]]; then
            echo "  For Telegram, WEBHOOK_URL should be your bot token."
            read -rp "Telegram chat ID: " telegram_chat_id
        fi
    fi

    # Write config
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" <<CONF
# docker-backup.conf - Generated by install.sh on $(date)
# Pull model: this runs on the backup server and pulls from production.

# Production server (where Docker containers run)
PRODUCTION_HOST=$production_host
PRODUCTION_USER=$production_user
PRODUCTION_PORT=$production_port
PRODUCTION_SOURCE_DIR=$production_source_dir
SSH_KEY=$SSH_KEY

# Staging directories (temporary, cleaned up after each run)
PRODUCTION_STAGING_DIR=/var/tmp/docker-backup-staging
BACKUP_STAGING_DIR=/var/tmp/docker-backup-staging

# Local backup storage (encrypted archives land here)
BACKUP_DIR=$backup_dir

# age encryption
AGE_RECIPIENT=$AGE_PUBLIC_KEY
AGE_KEY_FILE=$AGE_KEY_FILE

# Webhook notifications
WEBHOOK_URL=$webhook_url
WEBHOOK_TYPE=$webhook_type
TELEGRAM_CHAT_ID=$telegram_chat_id

# GFS retention policy
RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3

# zstd compression level (1-19, default 3 is a good speed/ratio trade-off)
COMPRESSION_LEVEL=3
CONF

    chmod 600 "$CONFIG_FILE"
    info "Config written: $CONFIG_FILE"
fi

# --- Install files ---
echo ""
info "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/lib"

cp "$SCRIPT_DIR/docker-backup" "$INSTALL_DIR/docker-backup"
chmod 755 "$INSTALL_DIR/docker-backup"

for lib_file in "$SCRIPT_DIR"/lib/*.sh; do
    cp "$lib_file" "$INSTALL_DIR/lib/"
done

info "Scripts installed"

# --- Install scheduling / init ---
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    info "Installing systemd units..."
    cp "$SCRIPT_DIR/docker-backup.service" "$SYSTEMD_DIR/"
    cp "$SCRIPT_DIR/docker-backup.timer" "$SYSTEMD_DIR/"

    systemctl daemon-reload
    systemctl enable docker-backup.timer
    systemctl start docker-backup.timer

    info "Timer enabled and started"
    echo "  Next trigger: $(systemctl show docker-backup.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo 'check with systemctl list-timers')"
elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    info "Installing OpenRC service..."
    cp "$SCRIPT_DIR/docker-backup.openrc" "$OPENRC_DIR/docker-backup"
    chmod 755 "$OPENRC_DIR/docker-backup"

    info "Installing cron job (daily at 03:00)..."
    # Add cron entry if not already present
    cron_entry="0 3 * * * /opt/docker-backup/docker-backup >> /var/log/docker-backup.log 2>&1"
    if [[ -f "$CRON_FILE" ]] && grep -qF '/opt/docker-backup/docker-backup' "$CRON_FILE"; then
        info "Cron entry already exists, skipping"
    else
        echo "$cron_entry" >> "$CRON_FILE"
        info "Cron entry added to $CRON_FILE"
    fi

    # Ensure crond is enabled and running
    rc-update add crond default 2>/dev/null || true
    rc-service crond start 2>/dev/null || true
    info "Cron job installed"
else
    warn "Unknown init system — skipping service/timer installation"
    warn "You'll need to manually schedule: $INSTALL_DIR/docker-backup"
fi

# --- Done ---
echo ""
bold "=== Installation Complete ==="
echo ""
info "Backup script:  $INSTALL_DIR/docker-backup"
info "Config file:    $CONFIG_FILE"
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    info "Timer status:   systemctl status docker-backup.timer"
    info "Manual run:     systemctl start docker-backup.service"
    info "View logs:      journalctl -u docker-backup.service"
elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    info "Cron schedule:  daily at 03:00 (see $CRON_FILE)"
    info "Manual run:     rc-service docker-backup start"
    info "View logs:      /var/log/docker-backup.log"
fi
echo ""
warn "Make sure the SSH public key is added to the PRODUCTION server's authorized_keys."
echo ""

# --- Offer test run ---
read -rp "Run a dry-run test now? [y/N] " test_run
if [[ "$test_run" =~ ^[Yy] ]]; then
    echo ""
    bold "=== Dry Run ==="
    "$INSTALL_DIR/docker-backup" --dry-run
fi
