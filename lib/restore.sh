#!/usr/bin/env bash
# restore.sh - Restore helpers for docker-backup

# Interactively restore database dumps found in a backup.
# Detects container/db/type from .backup.conf when available, falls back to
# filename parsing. Prompts the user for each dump before restoring.
# Usage: restore_databases /path/to/_dumps /path/to/service_dir
restore_databases() {
    local dump_dir="$1"
    local service_dir="$2"

    # Collect dump files
    local -a dump_files=()
    local f
    for f in "$dump_dir"/*.pgfc "$dump_dir"/*.sql; do
        [[ -e "$f" ]] || continue
        dump_files+=("$f")
    done

    if [[ ${#dump_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo "Database dumps found (${#dump_files[@]}):"

    # Build config-based lookup if .backup.conf exists
    # Maps "container_dbname" => "container|type"
    local -A config_map=()
    local conf_file="$service_dir/.backup.conf"

    if [[ -f "$conf_file" ]]; then
        # Source config in a subshell-safe way: clear old DB vars, source, parse
        unset_db_vars
        # shellcheck source=/dev/null
        source "$conf_file"

        local i=1
        while true; do
            local container_var="DB_${i}_CONTAINER"
            local type_var="DB_${i}_TYPE"
            local names_var="DB_${i}_NAMES"

            local container="${!container_var:-}"
            [[ -z "$container" ]] && break

            local db_type="${!type_var:-}"
            local db_names="${!names_var:-}"

            if [[ -n "$db_type" && -n "$db_names" ]]; then
                local db
                for db in ${db_names//,/ }; do
                    db="$(echo "$db" | xargs)"
                    [[ -z "$db" ]] && continue
                    config_map["${container}_${db}"]="${container}|${db_type}|${db}"
                done
            fi

            ((i++))
        done

        unset_db_vars
    fi

    local errors=0
    local restored=0
    local skipped=0

    for f in "${dump_files[@]}"; do
        local basename_f
        basename_f="$(basename "$f")"
        local stem="${basename_f%.*}"
        local ext="${basename_f##*.}"

        # Determine type from extension
        local detected_type=""
        case "$ext" in
            pgfc) detected_type="postgres" ;;
            sql)  detected_type="mysql" ;;
        esac

        # Resolve container, db name, type
        local container="" db_name="" db_type=""

        if [[ -n "${config_map[$stem]+_}" ]]; then
            # Config-based resolution
            IFS='|' read -r container db_type db_name <<< "${config_map[$stem]}"
        else
            # Filename fallback: split stem on first underscore
            container="${stem%%_*}"
            db_name="${stem#*_}"
            db_type="$detected_type"
        fi

        echo ""
        echo "  File:      $basename_f"
        echo "  Container: $container"
        echo "  Database:  $db_name"
        echo "  Type:      $db_type"

        local answer=""
        while true; do
            printf "  Restore this database? [y/N/edit] "
            read -r answer
            case "$answer" in
                y|Y) break ;;
                n|N|"")
                    echo "  Skipped."
                    ((skipped++))
                    break
                    ;;
                edit|Edit|EDIT)
                    printf "  Container name [%s]: " "$container"
                    read -r input
                    [[ -n "$input" ]] && container="$input"
                    printf "  Database name [%s]: " "$db_name"
                    read -r input
                    [[ -n "$input" ]] && db_name="$input"
                    printf "  Type (postgres/mysql) [%s]: " "$db_type"
                    read -r input
                    [[ -n "$input" ]] && db_type="$input"
                    echo "  Updated -> container=$container db=$db_name type=$db_type"
                    ;;
                *)
                    echo "  Please enter y, n, or edit."
                    ;;
            esac
        done

        [[ "$answer" == "n" || "$answer" == "N" || -z "$answer" ]] && continue

        # Verify container is running locally
        local running
        running="$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null)" || true
        if [[ "$running" != "true" ]]; then
            echo "  ERROR: Container '$container' is not running. Skipping."
            ((errors++))
            continue
        fi

        # Execute restore
        echo "  Restoring..."
        local restore_err=""
        case "$db_type" in
            postgres|postgresql)
                if restore_err="$(docker exec -i "$container" pg_restore -U postgres -d "$db_name" --clean --if-exists < "$f" 2>&1)"; then
                    echo "  OK: PostgreSQL restore complete."
                    ((restored++))
                else
                    echo "  ERROR: pg_restore failed: $restore_err"
                    ((errors++))
                fi
                ;;
            mysql|mariadb)
                if restore_err="$(docker exec -i "$container" mysql -u root "$db_name" < "$f" 2>&1)"; then
                    echo "  OK: MySQL restore complete."
                    ((restored++))
                else
                    echo "  ERROR: mysql restore failed: $restore_err"
                    ((errors++))
                fi
                ;;
            *)
                echo "  ERROR: Unknown database type '$db_type'. Skipping."
                ((errors++))
                ;;
        esac
    done

    echo ""
    echo "Database restore summary: $restored restored, $skipped skipped, $errors error(s)"

    [[ $errors -gt 0 ]] && return 1
    return 0
}

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
    service_name="$(echo "$filename" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\(_[0-9]\{6\}\)\{0,1\}\.tar\.zst\.age$//')"
    local dump_dir="$target_dir/$service_name/_dumps"

    if [[ -d "$dump_dir" ]]; then
        restore_databases "$dump_dir" "$target_dir/$service_name"
    fi

    # Cleanup working directory
    rm -rf "$work_dir"

    echo ""
    echo "Restore complete: $target_dir/$service_name"
    return 0
}
