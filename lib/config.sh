#!/usr/bin/env bash
# config.sh - Configuration parsing for docker-backup

# Load global configuration file
# Usage: load_global_config /path/to/docker-backup.conf
load_global_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Global config not found: $config_file"
        return 1
    fi

    # Source the config (it's just shell variable assignments)
    # shellcheck source=/dev/null
    source "$config_file"

    # Validate required settings
    local required_vars=(
        PRODUCTION_HOST
        PRODUCTION_USER
        PRODUCTION_SOURCE_DIR
        SSH_KEY
        BACKUP_DIR
        AGE_RECIPIENT
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required config variables: ${missing[*]}"
        return 1
    fi

    # Apply defaults for optional settings
    PRODUCTION_PORT="${PRODUCTION_PORT:-22}"
    PRODUCTION_STAGING_DIR="${PRODUCTION_STAGING_DIR:-/var/tmp/docker-backup-staging}"
    BACKUP_STAGING_DIR="${BACKUP_STAGING_DIR:-/var/tmp/docker-backup-staging}"
    RETAIN_DAILY="${RETAIN_DAILY:-7}"
    RETAIN_WEEKLY="${RETAIN_WEEKLY:-4}"
    RETAIN_MONTHLY="${RETAIN_MONTHLY:-3}"
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-3}"
    WEBHOOK_TYPE="${WEBHOOK_TYPE:-discord}"
    WEBHOOK_URL="${WEBHOOK_URL:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    AGE_KEY_FILE="${AGE_KEY_FILE:-}"

    return 0
}

# Load per-service .backup.conf from production via SSH
# Sets service-level variables with defaults for anything not specified.
# Usage: load_service_config /opt/docker/myapp
load_service_config() {
    local service_dir="$1"
    local config_file="$service_dir/.backup.conf"

    # Reset per-service variables to defaults
    BACKUP_MODE="hot"
    EXCLUDE=""
    PRE_BACKUP_HOOK=""
    POST_BACKUP_HOOK=""

    # Clear any previous DB_* variables
    unset_db_vars

    local remote_conf
    remote_conf="$(prod_ssh "cat '$config_file' 2>/dev/null")" || true

    if [[ -n "$remote_conf" ]]; then
        eval "$remote_conf"
        log_info "Loaded config: $config_file (from production)"
    else
        log_info "No .backup.conf for $(basename "$service_dir"), using defaults"
    fi

    # Validate BACKUP_MODE
    case "$BACKUP_MODE" in
        hot|stop-start) ;;
        *)
            log_warn "Invalid BACKUP_MODE='$BACKUP_MODE', defaulting to 'hot'"
            BACKUP_MODE="hot"
            ;;
    esac
}

# Clear all DB_N_* variables from previous service config
unset_db_vars() {
    local var
    for var in $(compgen -v | grep -E '^DB_[0-9]+_' || true); do
        unset "$var"
    done
}

# Parse database definitions from the current config.
# Returns lines in format: container|type|dbnames
# Usage: get_db_definitions
get_db_definitions() {
    local i=1
    while true; do
        local container_var="DB_${i}_CONTAINER"
        local type_var="DB_${i}_TYPE"
        local names_var="DB_${i}_NAMES"

        local container="${!container_var:-}"
        [[ -z "$container" ]] && break

        local db_type="${!type_var:-}"
        local db_names="${!names_var:-}"

        if [[ -z "$db_type" ]]; then
            log_warn "DB_${i}_TYPE not set for container $container, skipping"
            ((i++))
            continue
        fi

        echo "${container}|${db_type}|${db_names}"
        ((i++))
    done
}

# Discover docker-compose services on the production server via SSH.
# Prints one service directory path per line.
# Uses find to avoid shell-compatibility issues (remote shell may be zsh).
discover_services() {
    local source_dir="$1"

    local remote_files
    if ! remote_files="$(prod_ssh "find '${source_dir}' -mindepth 2 -maxdepth 2 \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \)" 2>&1)"; then
        log_error "Failed to connect to production server: $remote_files"
        return 1
    fi

    if [[ -z "$remote_files" ]]; then
        log_warn "No docker-compose services found in $source_dir on production"
        return 0
    fi

    # Strip compose filenames to get service directories, deduplicate
    echo "$remote_files" | sed 's|/[^/]*$||' | sort -u
    return 0
}
