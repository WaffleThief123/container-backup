#!/usr/bin/env bash
# transfer.sh - rsync transfer to remote server over SSH

# Build the SSH command string used by rsync and remote operations.
# Usage: ssh_cmd
ssh_cmd() {
    echo "ssh -i ${SSH_KEY} -p ${REMOTE_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
}

# Transfer all encrypted archives from staging to remote.
# Usage: transfer_archives /var/tmp/backups
transfer_archives() {
    local staging_dir="$1"
    local remote_dest="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

    # Ensure remote directory exists
    $(ssh_cmd) "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_PATH}'" 2>/tmp/ssh_err
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create remote directory: $(cat /tmp/ssh_err)"
        return 1
    fi

    # Count files to transfer
    local file_count
    file_count="$(find "$staging_dir" -name '*.age' -type f 2>/dev/null | wc -l)"
    if [[ "$file_count" -eq 0 ]]; then
        log_warn "No encrypted archives found in staging directory"
        return 0
    fi

    log_info "Transferring $file_count archive(s) to $REMOTE_HOST:$REMOTE_PATH"

    local start_time
    start_time=$(date +%s)

    if rsync -a --partial \
        -e "$(ssh_cmd)" \
        "$staging_dir/"*.age \
        "$remote_dest" 2>/tmp/rsync_err; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "Transfer complete in ${duration}s"
        return 0
    else
        log_error "rsync failed: $(cat /tmp/rsync_err)"
        return 1
    fi
}

# List backups on the remote server.
# Optional filter by service name.
# Usage: list_remote_backups [service_name]
list_remote_backups() {
    local service_filter="${1:-}"
    local pattern="*.tar.zst.age"

    if [[ -n "$service_filter" ]]; then
        pattern="${service_filter}-*.tar.zst.age"
    fi

    $(ssh_cmd) "${REMOTE_USER}@${REMOTE_HOST}" \
        "ls -lh '${REMOTE_PATH}/'${pattern} 2>/dev/null" 2>/dev/null
}

# Download a specific backup from remote.
# Usage: download_backup filename /local/destination/
download_backup() {
    local filename="$1"
    local dest_dir="$2"
    local remote_file="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${filename}"

    mkdir -p "$dest_dir"

    log_info "Downloading: $filename"

    if rsync -a --partial --progress \
        -e "$(ssh_cmd)" \
        "$remote_file" \
        "$dest_dir/" 2>/tmp/rsync_err; then

        log_info "Download complete: $dest_dir/$filename"
        echo "$dest_dir/$filename"
        return 0
    else
        log_error "Download failed: $(cat /tmp/rsync_err)"
        return 1
    fi
}
