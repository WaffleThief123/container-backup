#!/usr/bin/env bash
# database.sh - Database dump logic via docker exec on production server

# Dump all configured databases for a service.
# Creates dumps in $service_dir/_dumps/ on production.
# Usage: dump_databases /opt/docker/myapp
dump_databases() {
    local service_dir="$1"
    local dump_dir="$service_dir/_dumps"
    local errors=0

    # Get database definitions from config
    local db_defs
    db_defs="$(get_db_definitions)"
    [[ -z "$db_defs" ]] && return 0

    prod_ssh "mkdir -p '$dump_dir'"

    while IFS='|' read -r container db_type db_names; do
        [[ -z "$container" ]] && continue

        # Check container is running on production
        local running
        running="$(prod_ssh "docker inspect --format='{{.State.Running}}' '$container' 2>/dev/null")" || true
        if [[ "$running" != "true" ]]; then
            log_error "Container $container is not running on production, cannot dump"
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

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# Dump PostgreSQL databases via docker exec on production
# Usage: dump_postgres container_name "db1,db2" /path/to/dumps
dump_postgres() {
    local container="$1"
    local db_names="$2"
    local dump_dir="$3"

    if [[ "$db_names" == "all" ]]; then
        log_info "Dumping all PostgreSQL databases from $container"
        local db_list
        db_list="$(prod_ssh "docker exec '$container' psql -U postgres -At -c \
            \"SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';\"" 2>&1)"
        if [[ $? -ne 0 ]]; then
            log_error "Failed to list databases from $container: $db_list"
            return 1
        fi
        db_names="$(echo "$db_list" | paste -sd,)"
    fi

    local errors=0
    local db
    for db in ${db_names//,/ }; do
        db="$(echo "$db" | xargs)"
        [[ -z "$db" ]] && continue

        local dump_file="$dump_dir/${container}_${db}.pgfc"
        log_info "Dumping PostgreSQL: $container/$db -> $(basename "$dump_file")"

        local dump_err
        if dump_err="$(prod_ssh "docker exec '$container' pg_dump -U postgres -Fc '$db' > '$dump_file'" 2>&1)"; then
            local size
            size="$(prod_ssh "du -h '$dump_file' | cut -f1")"
            log_info "  Dump complete: $size"
        else
            log_error "  pg_dump failed for $container/$db: $dump_err"
            prod_ssh "rm -f '$dump_file'"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# Dump MySQL/MariaDB databases via docker exec on production
# Usage: dump_mysql container_name "db1,db2" /path/to/dumps
dump_mysql() {
    local container="$1"
    local db_names="$2"
    local dump_dir="$3"

    # Detect available commands (mariadb-dump/mysqldump, mariadb/mysql)
    local dump_cmd="mysqldump"
    local client_cmd="mysql"
    if prod_ssh "docker exec '$container' sh -c 'command -v mariadb-dump'" &>/dev/null; then
        dump_cmd="mariadb-dump"
        client_cmd="mariadb"
    fi

    if [[ "$db_names" == "all" ]]; then
        log_info "Dumping all MySQL databases from $container"
        local db_list
        db_list="$(prod_ssh "docker exec '$container' sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" $client_cmd -u root -N -e \"SHOW DATABASES;\"' | grep -Ev '^(information_schema|performance_schema|mysql|sys)\$'" 2>&1)"
        if [[ $? -ne 0 ]]; then
            log_error "Failed to list databases from $container: $db_list"
            return 1
        fi
        db_names="$(echo "$db_list" | paste -sd,)"
    fi

    local errors=0
    local db
    for db in ${db_names//,/ }; do
        db="$(echo "$db" | xargs)"
        [[ -z "$db" ]] && continue

        local dump_file="$dump_dir/${container}_${db}.sql"
        log_info "Dumping MySQL: $container/$db -> $(basename "$dump_file") (via $dump_cmd)"

        local dump_err
        if dump_err="$(prod_ssh "docker exec '$container' sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" $dump_cmd -u root --single-transaction $db' > '$dump_file'" 2>&1)"; then
            local size
            size="$(prod_ssh "du -h '$dump_file' | cut -f1")"
            log_info "  Dump complete: $size"
        else
            log_error "  mysqldump failed for $container/$db: $dump_err"
            prod_ssh "rm -f '$dump_file'"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# Clean up dump directory on production after archive is created
# Usage: cleanup_dumps /opt/docker/myapp
cleanup_dumps() {
    local service_dir="$1"
    local dump_dir="$service_dir/_dumps"

    prod_ssh "rm -rf '$dump_dir'" 2>/dev/null
    log_info "Cleaned up dumps: $dump_dir (on production)"
}
