#!/usr/bin/env bash
# restore.sh - Restore helpers for docker-backup

# List available backups in local BACKUP_DIR, optionally filtered by service.
# Usage: restore_list [service_name]
restore_list() {
    local service_filter="${1:-}"

    echo "Available backups in ${BACKUP_DIR}/"
    echo "---"

    local files
    files="$(list_local_backups "$service_filter")"

    if [[ -z "$files" ]]; then
        echo "No backups found."
        return 1
    fi

    echo "$files"
    return 0
}

# Restore a backup archive from local BACKUP_DIR.
# Usage: restore_backup filename [target_dir]
restore_backup() {
    local filename="$1"
    local target_dir="${2:-/tmp/docker-backup-restore}"
    local source_file="$BACKUP_DIR/$filename"

    local work_dir="$target_dir/.restore-work"
    mkdir -p "$work_dir"

    echo "Restoring: $filename"
    echo "Source: $source_file"
    echo "Target: $target_dir"
    echo ""

    if [[ ! -f "$source_file" ]]; then
        echo "ERROR: Backup file not found: $source_file"
        rm -rf "$work_dir"
        return 1
    fi

    # Step 1: Decrypt
    echo "Step 1/3: Decrypting..."
    local decrypted="$work_dir/$(basename "${filename%.age}")"
    if ! decrypt_file "$source_file" "$decrypted" >/dev/null; then
        echo "ERROR: Decryption failed"
        rm -rf "$work_dir"
        return 1
    fi

    # Step 2: Decompress + extract
    echo "Step 2/3: Extracting..."
    local tar_err
    if ! tar_err="$(tar -I 'zstd -d' -xf "$decrypted" -C "$target_dir" 2>&1)"; then
        echo "ERROR: Extraction failed: $tar_err"
        rm -rf "$work_dir"
        return 1
    fi
    rm -f "$decrypted"

    # Step 3: Check for database dumps
    echo "Step 3/3: Checking for database dumps..."
    local service_name
    service_name="$(echo "$filename" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\.tar\.zst\.age$//')"
    local dump_dir="$target_dir/$service_name/_dumps"

    if [[ -d "$dump_dir" ]]; then
        echo ""
        echo "Database dumps found in $dump_dir:"
        ls -lh "$dump_dir/"
        echo ""
        echo "To restore PostgreSQL dumps:"
        echo "  docker exec -i <container> pg_restore -U postgres -d <dbname> < dump.pgfc"
        echo ""
        echo "To restore MySQL dumps:"
        echo "  docker exec -i <container> mysql -u root <dbname> < dump.sql"
    fi

    # Cleanup working directory
    rm -rf "$work_dir"

    echo ""
    echo "Restore complete: $target_dir/$service_name"
    return 0
}

# Restore database dumps from an already-extracted backup.
# Usage: restore_database dump_file container_name db_type db_name
restore_database() {
    local dump_file="$1"
    local container="$2"
    local db_type="$3"
    local db_name="$4"

    if [[ ! -f "$dump_file" ]]; then
        log_error "Dump file not found: $dump_file"
        return 1
    fi

    # Check container is running
    if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        log_error "Container $container is not running"
        return 1
    fi

    case "$db_type" in
        postgres|postgresql)
            log_info "Restoring PostgreSQL dump to $container/$db_name"
            if docker exec -i "$container" pg_restore -U postgres -d "$db_name" --clean --if-exists < "$dump_file" 2>/tmp/restore_err; then
                log_info "  PostgreSQL restore complete"
            else
                log_warn "  pg_restore reported warnings: $(cat /tmp/restore_err)"
                log_info "  (Warnings during pg_restore are often non-fatal)"
            fi
            ;;
        mysql|mariadb)
            log_info "Restoring MySQL dump to $container/$db_name"
            if docker exec -i "$container" mysql -u root "$db_name" < "$dump_file" 2>/tmp/restore_err; then
                log_info "  MySQL restore complete"
            else
                log_error "  MySQL restore failed: $(cat /tmp/restore_err)"
                return 1
            fi
            ;;
        *)
            log_error "Unknown database type: $db_type"
            return 1
            ;;
    esac

    return 0
}
