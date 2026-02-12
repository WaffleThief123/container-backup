#!/usr/bin/env bash
# uninstall.sh - Remove docker-backup from the backup server
set -euo pipefail

INSTALL_DIR="/opt/docker-backup"
SYSTEMD_DIR="/etc/systemd/system"
OPENRC_DIR="/etc/init.d"
CRON_FILE="/etc/crontabs/root"
CONFIG_FILE="$INSTALL_DIR/docker-backup.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

INIT_SYSTEM="$(detect_init)"

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

bold "=== Docker Backup Uninstaller ==="
echo ""

# --- Check if installed ---
if [[ ! -d "$INSTALL_DIR" ]]; then
    error "docker-backup does not appear to be installed ($INSTALL_DIR not found)"
    exit 1
fi

# --- Read config before removing files ---
BACKUP_DIR=""
if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_DIR="$(grep -E '^BACKUP_DIR=' "$CONFIG_FILE" | cut -d= -f2- || true)"
fi

# --- Stop and disable scheduling ---
info "Removing scheduling (init: $INIT_SYSTEM)..."

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    if systemctl is-active --quiet docker-backup.timer 2>/dev/null; then
        systemctl stop docker-backup.timer
    fi
    systemctl disable docker-backup.timer 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/docker-backup.service" "$SYSTEMD_DIR/docker-backup.timer"
    systemctl daemon-reload
    info "Systemd timer and service removed"

elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    if [[ -f "$OPENRC_DIR/docker-backup" ]]; then
        rc-service docker-backup stop 2>/dev/null || true
        rm -f "$OPENRC_DIR/docker-backup"
        info "OpenRC service removed"
    fi
    if [[ -f "$CRON_FILE" ]] && grep -qF '/opt/docker-backup/docker-backup' "$CRON_FILE"; then
        sed -i '\|/opt/docker-backup/docker-backup|d' "$CRON_FILE"
        info "Cron entry removed from $CRON_FILE"
    fi
else
    warn "Unknown init system — check for leftover scheduled tasks manually"
fi

# --- Remove install directory ---
info "Removing $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
info "Install directory removed"

# --- Prompt: SSH key ---
echo ""
SSH_KEY="/root/.ssh/backup_ed25519"
if [[ -f "$SSH_KEY" ]] || [[ -f "${SSH_KEY}.pub" ]]; then
    warn "SSH key found: $SSH_KEY"
    read -rp "Remove SSH keypair? [y/N] " remove_ssh
    if [[ "$remove_ssh" =~ ^[Yy] ]]; then
        rm -f "$SSH_KEY" "${SSH_KEY}.pub"
        info "SSH keypair removed"
    else
        info "Keeping SSH keypair"
    fi
fi

# --- Prompt: age key ---
AGE_KEY_FILE="/root/.age/backup.key"
if [[ -f "$AGE_KEY_FILE" ]]; then
    echo ""
    warn "Age private key found: $AGE_KEY_FILE"
    warn "WITHOUT THIS KEY, EXISTING BACKUPS CANNOT BE DECRYPTED."
    read -rp "Remove age keypair? [y/N] " remove_age
    if [[ "$remove_age" =~ ^[Yy] ]]; then
        rm -f "$AGE_KEY_FILE"
        # Remove directory only if empty
        rmdir /root/.age 2>/dev/null || true
        info "Age keypair removed"
    else
        info "Keeping age keypair"
    fi
fi

# --- Prompt: backup data ---
if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
    echo ""
    warn "Backup data directory found: $BACKUP_DIR"
    warn "This will permanently delete ALL backup archives."
    read -rp "Remove backup data? [y/N] " remove_data
    if [[ "$remove_data" =~ ^[Yy] ]]; then
        rm -rf "$BACKUP_DIR"
        info "Backup data removed"
    else
        info "Keeping backup data"
    fi
fi

# --- Summary ---
echo ""
bold "=== Uninstall Complete ==="
echo ""
info "Removed: scheduling, scripts, and config"

if [[ -f "$SSH_KEY" ]]; then
    info "Kept:    SSH key ($SSH_KEY)"
fi
if [[ -f "$AGE_KEY_FILE" ]]; then
    info "Kept:    age key ($AGE_KEY_FILE)"
fi
if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
    info "Kept:    backup data ($BACKUP_DIR)"
fi
echo ""
