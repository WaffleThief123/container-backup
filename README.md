# docker-backup

Encrypted offsite backups for Docker Compose projects. Designed for a single server running multiple Compose stacks under one parent directory.

Backs up each service as an independent archive: database dumps via `docker exec`, tar + zstd compression, age encryption, rsync to a remote server over SSH, with GFS retention and webhook notifications.

## Requirements

- `age` - encryption
- `zstd` - compression
- `rsync` - transfer
- `docker` - container access for DB dumps
- `jq` - JSON payload construction for webhooks
- `curl` - webhook delivery
- `ssh` - remote server access

On Arch: `pacman -S age zstd rsync docker jq curl openssh`

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
4. Print the SSH public key for you to add to the remote server
5. Prompt for remote host details and write the config
6. Install scripts to `/opt/docker-backup/`
7. Enable and start the systemd timer (nightly at 03:00)
8. Offer an immediate dry-run test

## How It Works

Given a source directory (default `/opt/docker`) containing Compose project subdirectories:

```
/opt/docker/
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

1. Load `.backup.conf` if present (otherwise: hot backup, no DB dumps)
2. Run the pre-backup hook if configured
3. Stop containers if `BACKUP_MODE=stop-start`
4. Dump databases via `docker exec` into a `_dumps/` subdirectory
5. Create a `tar.zst` archive of the service directory (including dumps)
6. Restart containers if they were stopped
7. Run the post-backup hook if configured
8. Encrypt the archive with `age`
9. Transfer to the remote server with `rsync`
10. Apply GFS retention pruning on the remote
11. Clean up local staging files
12. Send a webhook notification with the summary

Output files are named `servicename-YYYY-MM-DD.tar.zst.age`.

## Configuration

### Global Config

Located at `/opt/docker-backup/docker-backup.conf` after installation:

```ini
BACKUP_SOURCE_DIR=/opt/docker
BACKUP_LOCAL_STAGING=/var/tmp/backups

REMOTE_HOST=backup.example.com
REMOTE_USER=backup
REMOTE_PORT=22
REMOTE_PATH=/backups/ovh-main
SSH_KEY=/root/.ssh/backup_ed25519

AGE_RECIPIENT=age1xxxxxxxxx...
AGE_KEY_FILE=/root/.age/backup.key

WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
WEBHOOK_TYPE=discord   # discord | slack | telegram

# For Telegram: set WEBHOOK_URL to the bot token, and set TELEGRAM_CHAT_ID
#WEBHOOK_URL=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
#TELEGRAM_CHAT_ID=-1001234567890

RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3
COMPRESSION_LEVEL=3    # zstd level 1-19
```

### Per-Service Config

Place a `.backup.conf` in any Compose project directory to customize its backup behavior:

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

# Optional hooks
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

# Skip transfer (local archive only):
docker-backup --no-transfer

# Use a different config file:
docker-backup --config /path/to/docker-backup.conf

# Combine flags:
docker-backup --service gitea --no-prune --no-notify
```

## Restore

```bash
# List all available backups on the remote server:
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

Backups are pruned on the remote server after each transfer:

| Tier    | Kept | Rule                        |
|---------|------|-----------------------------|
| Daily   | 7    | Most recent 7 backups       |
| Weekly  | 4    | Last 4 Sunday backups       |
| Monthly | 3    | Last 3 first-of-month backups |

All counts are configurable via `RETAIN_DAILY`, `RETAIN_WEEKLY`, `RETAIN_MONTHLY`.

## Systemd

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

## SSH Setup on the Remote Server

On the remote backup server, create a dedicated user and authorize the key:

```bash
# On the remote server:
useradd -m -s /bin/bash backup
mkdir -p /backups/ovh-main
chown backup:backup /backups/ovh-main

# Add the public key printed during install:
mkdir -p /home/backup/.ssh
echo "ssh-ed25519 AAAA... docker-backup@hostname" >> /home/backup/.ssh/authorized_keys
chmod 700 /home/backup/.ssh
chmod 600 /home/backup/.ssh/authorized_keys
chown -R backup:backup /home/backup/.ssh
```

Optionally restrict the key to rsync-only in `authorized_keys`:

```
command="rrsync /backups/ovh-main",no-pty,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA...
```

Note: the retention pruning step runs `rm` on the remote via SSH, so a fully locked-down `rrsync` setup would need to handle that separately (e.g. a cron job on the remote running its own pruning script). If you use `rrsync`, set `--no-prune` and manage retention on the remote side.

## Security Notes

- The remote server only stores encrypted blobs. Compromise of the backup server does not expose data.
- The age private key (`/root/.age/backup.key`) stays on the source server only. **Back it up separately** - without it, backups are irrecoverable.
- The SSH key is dedicated to backups, making it easy to revoke independently.
- All archives are encrypted individually, so a single corrupted file doesn't affect others.

## File Structure

```
/opt/docker-backup/
├── docker-backup              # main script
├── docker-backup.conf         # global config
└── lib/
    ├── config.sh              # config parsing + service discovery
    ├── database.sh            # pg_dump / mysqldump via docker exec
    ├── archive.sh             # tar + zstd compression
    ├── encrypt.sh             # age encrypt/decrypt
    ├── transfer.sh            # rsync over SSH
    ├── retention.sh           # GFS pruning on remote
    ├── notify.sh              # Discord/Slack webhooks
    └── restore.sh             # download + decrypt + extract
```
