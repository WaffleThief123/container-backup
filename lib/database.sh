#!/usr/bin/env bash
# database.sh - Database dump logic via docker exec

# Dump all configured databases for a service.
# Creates dumps in $service_dir/_dumps/
# Usage: dump_databases /opt/docker/myapp
dump_databases() {
    local service_dir="$1"
    local dump_dir="$service_dir/_dumps"
    local errors=0

    # Get database definitions from config
    local db_defs
    db_defs="$(get_db_definitions)"
    [[ -z "$db_defs" ]] && return 0

    mkdir -p "$dump_dir"

    while IFS='|' read -r container db_type db_names; do
        [[ -z "$container" ]] && continue

        # Check container is running
        if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
            log_error "Container $container is not running, cannot dump"
            ((errors++))
            continue
        fi

        case "$db_type" in
            postgres|postgresql)
                dump_postgres "$container" "$db_names" "$dump_dir" || ((errors++))
                ;;
            mysql|mariadb)
                dump_mysql "$container" "$db_names" "$dump_dir" || ((errors++))
                ;;
            *)
                log_error "Unknown database type: $db_type for container $container"
                ((errors++))
                ;;
        esac
    done <<< "$db_defs"

    return $errors
}

# Dump PostgreSQL databases via docker exec
# Usage: dump_postgres container_name "db1,db2" /path/to/dumps
dump_postgres() {
    local container="$1"
    local db_names="$2"
    local dump_dir="$3"

    if [[ "$db_names" == "all" ]]; then
        log_info "Dumping all PostgreSQL databases from $container"
        local db_list
        db_list="$(docker exec "$container" psql -U postgres -At -c \
            "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>&1)"
        if [[ $? -ne 0 ]]; then
            log_error "Failed to list databases from $container: $db_list"
            return 1
        fi
        db_names="$(echo "$db_list" | paste -sd,)"
    fi

    local IFS=','
    local errors=0
    for db in $db_names; do
        db="$(echo "$db" | xargs)"
        [[ -z "$db" ]] && continue

        local dump_file="$dump_dir/${container}_${db}.pgfc"
        log_info "Dumping PostgreSQL: $container/$db -> $(basename "$dump_file")"

        if docker exec "$container" pg_dump -U postgres -Fc "$db" > "$dump_file" 2>/tmp/pgdump_err; then
            local size
            size="$(du -h "$dump_file" | cut -f1)"
            log_info "  Dump complete: $size"
        else
            log_error "  pg_dump failed for $container/$db: $(cat /tmp/pgdump_err)"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    return $errors
}

# Dump MySQL/MariaDB databases via docker exec
# Usage: dump_mysql container_name "db1,db2" /path/to/dumps
dump_mysql() {
    local container="$1"
    local db_names="$2"
    local dump_dir="$3"

    if [[ "$db_names" == "all" ]]; then
        log_info "Dumping all MySQL databases from $container"
        local db_list
        db_list="$(docker exec "$container" mysql -u root -N -e \
            "SHOW DATABASES;" 2>&1 | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')"
        if [[ $? -ne 0 ]]; then
            log_error "Failed to list databases from $container: $db_list"
            return 1
        fi
        db_names="$(echo "$db_list" | paste -sd,)"
    fi

    local IFS=','
    local errors=0
    for db in $db_names; do
        db="$(echo "$db" | xargs)"
        [[ -z "$db" ]] && continue

        local dump_file="$dump_dir/${container}_${db}.sql"
        log_info "Dumping MySQL: $container/$db -> $(basename "$dump_file")"

        if docker exec "$container" mysqldump -u root --single-transaction "$db" > "$dump_file" 2>/tmp/mysqldump_err; then
            local size
            size="$(du -h "$dump_file" | cut -f1)"
            log_info "  Dump complete: $size"
        else
            log_error "  mysqldump failed for $container/$db: $(cat /tmp/mysqldump_err)"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    return $errors
}

# Clean up dump directory after archive is created
# Usage: cleanup_dumps /opt/docker/myapp
cleanup_dumps() {
    local service_dir="$1"
    local dump_dir="$service_dir/_dumps"

    if [[ -d "$dump_dir" ]]; then
        rm -rf "$dump_dir"
        log_info "Cleaned up dumps: $dump_dir"
    fi
}
