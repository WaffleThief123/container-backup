#!/usr/bin/env bash
# transfer.sh - SSH and rsync operations for pulling backups from production

# Build the SSH command string used by rsync and remote operations.
# Usage: prod_ssh_cmd
prod_ssh_cmd() {
    echo "ssh -T -i ${SSH_KEY} -p ${PRODUCTION_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
}

# Execute a command on the production server via SSH.
# Usage: prod_ssh "docker ps" or prod_ssh "ls -la /opt/docker"
prod_ssh() {
    $(prod_ssh_cmd) "${PRODUCTION_USER}@${PRODUCTION_HOST}" "$@"
}

# Pull a single archive from production staging to local destination via rsync.
# Usage: pull_archive remote_filename local_dest_dir
pull_archive() {
    local remote_file="$1"
    local local_dest="$2"
    local remote_src="${PRODUCTION_USER}@${PRODUCTION_HOST}:${PRODUCTION_STAGING_DIR}/${remote_file}"

    mkdir -p "$local_dest"

    log_info "Pulling archive: $remote_file"

    local start_time
    start_time=$(date +%s)

    local rsync_err
    if rsync_err="$(rsync -a --partial \
        -e "$(prod_ssh_cmd)" \
        "$remote_src" \
        "$local_dest/" 2>&1)"; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "Pull complete in ${duration}s"
        return 0
    else
        log_error "rsync pull failed: $rsync_err"
        return 1
    fi
}

# List backups in the local backup directory.
# Optional filter by service name.
# Usage: list_local_backups [service_name]
list_local_backups() {
    local service_filter="${1:-}"
    local pattern="*.tar.zst.age"

    if [[ -n "$service_filter" ]]; then
        pattern="${service_filter}-*.tar.zst.age"
    fi

    ls -lh "${BACKUP_DIR}/"${pattern} 2>/dev/null
}
