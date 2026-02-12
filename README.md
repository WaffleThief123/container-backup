# docker-backup

Encrypted pull-model backups for Docker Compose services. Runs on a **backup server** and pulls from production over SSH.

For each discovered service: dumps databases via `docker exec`, creates a tar+zstd archive on production, pulls it via rsync, encrypts locally with age, and applies GFS retention. Supports Discord, Slack, and Telegram notifications.

## Architecture

```
Production Server                         Backup Server
(Docker, tar, zstd)                       (age, rsync, ssh)

  /opt/docker/
  ├── traefik/          ──── SSH ────>    docker-backup runs here
  ├── nextcloud/        <─── rsync ───    pulls archives over SSH
  └── gitea/                              encrypts + stores locally
```

- Archives are created on production (rsync can resume partial transfers)
- Encryption happens on the backup server (age keys never touch production)
- Retention pruning is local filesystem operations (no SSH)

## Requirements

**Backup server** (where docker-backup runs):

- `bash`, `age`, `zstd`, `rsync`, `jq`, `curl`, `ssh`, `tar`

**Production server** (where containers run):

- `bash`, `tar`, `zstd`, `docker`

On Arch: `pacman -S age zstd rsync jq curl openssh`

## Quick Start

```bash
git clone <repo> /tmp/backup-tools
cd /tmp/backup-tools
sudo ./install.sh
```

The installer will:

1. Check all dependencies are present
2. Generate an age keypair at `/root/.age/backup.key` (if not already present)
3. Generate a dedicated SSH key at `/root/.ssh/backup_ed25519`
4. Print the SSH public key for you to add to the **production** server
5. Prompt for production host details and local backup directory
6. Write the config and install scripts to `/opt/docker-backup/`
7. Enable the systemd timer or cron job (nightly at 03:00)
8. Offer an immediate dry-run test

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes scheduling (systemd timer or cron), scripts, and config from `/opt/docker-backup/`. It then prompts before removing the SSH key, age keypair, or backup data — all default to **no** to prevent accidental data loss.

## How It Works

Given a source directory on production (default `/opt/docker`) containing Compose project subdirectories:

```
/opt/docker/          (on production)
├── traefik/
│   ├── docker-compose.yml
│   └── ...
├── nextcloud/
│   ├── docker-compose.yml
│   ├── .backup.conf          # per-service config
│   └── ...
└── gitea/
    ├── compose.yml
    └── ...
```

For each service, docker-backup will:

1. Load `.backup.conf` from production via SSH (defaults: hot backup, no DB dumps)
2. Run the pre-backup hook on production if configured
3. Stop containers on production if `BACKUP_MODE=stop-start`
4. Dump databases via `docker exec` on production into a `_dumps/` subdirectory
5. Create a `tar.zst` archive on production in a staging directory
6. Restart containers on production if they were stopped
7. Run the post-backup hook on production if configured
8. Pull the archive to the backup server via rsync
9. Encrypt with age locally and store in `BACKUP_DIR`
10. Clean up staging on both sides
11. Apply GFS retention pruning on local `BACKUP_DIR`
12. Send a webhook notification with the summary

Output files are named `servicename-YYYY-MM-DD.tar.zst.age`.

## Configuration

### Global Config

Located at `/opt/docker-backup/docker-backup.conf` after installation:

```ini
# Production server (where Docker containers run)
PRODUCTION_HOST=prod.example.com
PRODUCTION_USER=root
PRODUCTION_PORT=22
PRODUCTION_SOURCE_DIR=/opt/docker
SSH_KEY=/root/.ssh/backup_ed25519

# Staging directories (temporary, cleaned up after each run)
PRODUCTION_STAGING_DIR=/var/tmp/docker-backup-staging
BACKUP_STAGING_DIR=/var/tmp/docker-backup-staging

# Local backup storage (encrypted archives land here)
BACKUP_DIR=/backups/prod

# age encryption
AGE_RECIPIENT=age1xxxxxxxxx...
AGE_KEY_FILE=/root/.age/backup.key

# Webhook notifications
WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
WEBHOOK_TYPE=discord   # discord | slack | telegram

# For Telegram: set WEBHOOK_URL to the bot token, and set TELEGRAM_CHAT_ID
#WEBHOOK_URL=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
#TELEGRAM_CHAT_ID=-1001234567890

# GFS retention policy
RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3

# zstd compression level (1-19, default 3)
COMPRESSION_LEVEL=3
```

### Per-Service Config

Place a `.backup.conf` in any Compose project directory on production to customize its backup behavior:

```ini
# /opt/docker/myapp/.backup.conf
BACKUP_MODE=hot            # hot | stop-start
EXCLUDE="*.log,tmp/*"      # comma-separated exclude patterns

# Database dumps (numbered, can have multiple)
DB_1_CONTAINER=myapp-postgres
DB_1_TYPE=postgres          # postgres | mysql | mariadb
DB_1_NAMES=myapp_db         # comma-separated, or "all"

DB_2_CONTAINER=myapp-mysql
DB_2_TYPE=mysql
DB_2_NAMES=app_db,other_db

# Optional hooks (run on production via SSH)
PRE_BACKUP_HOOK="docker exec myapp-redis redis-cli BGSAVE"
POST_BACKUP_HOOK=""
```

**Backup modes:**

- `hot` (default) - archive the directory while containers keep running. Good for stateless services or those with their own crash recovery.
- `stop-start` - stop containers before archiving, start them after. Use for services that don't tolerate concurrent file access (e.g. SQLite-based apps).

**Database dump details:**

- PostgreSQL: uses `pg_dump -Fc` (custom format) for smaller dumps and selective restore
- MySQL/MariaDB: uses `mysqldump --single-transaction` for InnoDB consistency without locking
- Set `DB_N_NAMES=all` to dump every user database in the container

Services without a `.backup.conf` are backed up in hot mode with no database dumps - just a tar of the entire directory.

## Usage

```bash
# Normal nightly run (via systemd timer, or manually):
docker-backup

# Dry run - shows what would happen without making changes:
docker-backup --dry-run

# Back up a single service:
docker-backup --service nextcloud

# Use a different config file:
docker-backup --config /path/to/docker-backup.conf

# Combine flags:
docker-backup --service gitea --no-prune --no-notify
```

## Restore

Backups are stored locally in `BACKUP_DIR`, so restores read directly from disk:

```bash
# List all available backups:
docker-backup restore --list

# List backups for a specific service:
docker-backup restore --list nextcloud

# Restore a backup to a directory:
docker-backup restore --file nextcloud-2026-02-11.tar.zst.age --target /tmp/restore

# Restore to default location (/tmp/docker-backup-restore):
docker-backup restore --file nextcloud-2026-02-11.tar.zst.age
```

After extraction, if database dumps are found, the tool prints restore commands:

```bash
# PostgreSQL:
docker exec -i myapp-postgres pg_restore -U postgres -d myapp_db --clean --if-exists < dump.pgfc

# MySQL:
docker exec -i myapp-mysql mysql -u root myapp_db < dump.sql
```

## GFS Retention

Backups are pruned locally after each run:

| Tier    | Kept | Rule                        |
|---------|------|-----------------------------|
| Daily   | 7    | Most recent 7 backups       |
| Weekly  | 4    | Last 4 Sunday backups       |
| Monthly | 3    | Last 3 first-of-month backups |

All counts are configurable via `RETAIN_DAILY`, `RETAIN_WEEKLY`, `RETAIN_MONTHLY`.

## Scheduling

### Systemd

The timer runs nightly at 03:00 with up to 5 minutes of random jitter and `Persistent=true` (catches up if the server was off).

```bash
# Check timer status:
systemctl status docker-backup.timer
systemctl list-timers docker-backup.timer

# Trigger a manual run:
systemctl start docker-backup.service

# View logs:
journalctl -u docker-backup.service
journalctl -u docker-backup.service -f   # follow live

# Disable:
systemctl disable --now docker-backup.timer
```

### OpenRC / Alpine

On Alpine or other OpenRC systems, the installer adds a cron job (daily at 03:00):

```bash
# View logs:
cat /var/log/docker-backup.log

# Manual run:
/opt/docker-backup/docker-backup
```

## SSH Setup on the Production Server

On the production server, authorize the backup server's SSH key:

```bash
# Add the public key printed during install:
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAA... docker-backup@backuphost" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

The backup server needs SSH access to run `docker`, `tar`, and `zstd` on production. If you want to restrict the key, you can use a `ForceCommand` wrapper that only permits the specific commands docker-backup uses.

## Security Notes

- The production server never sees the age keys. Compromise of production does not expose past backups.
- The age private key (`/root/.age/backup.key`) stays on the backup server only. **Back it up separately** - without it, backups are irrecoverable.
- The SSH key is dedicated to backups, making it easy to revoke independently.
- All archives are encrypted individually, so a single corrupted file doesn't affect others.
- Per-service `.backup.conf` files are evaluated on the backup server. Only trusted production servers should be configured.

## File Structure

```
/opt/docker-backup/
├── docker-backup              # main script
├── docker-backup.conf         # global config
└── lib/
    ├── config.sh              # config parsing + remote service discovery
    ├── database.sh            # pg_dump / mysqldump via docker exec over SSH
    ├── archive.sh             # tar + zstd on production via SSH
    ├── encrypt.sh             # age encrypt/decrypt (local)
    ├── transfer.sh            # SSH wrapper + rsync pull
    ├── retention.sh           # GFS pruning (local)
    ├── notify.sh              # Discord/Slack/Telegram webhooks
    └── restore.sh             # decrypt + extract from local BACKUP_DIR
```
