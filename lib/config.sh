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
        BACKUP_SOURCE_DIR
        BACKUP_LOCAL_STAGING
        REMOTE_HOST
        REMOTE_USER
        REMOTE_PATH
        SSH_KEY
        AGE_RECIPIENT
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required config variables: ${missing[*]}"
        return 1
    fi

    # Apply defaults for optional settings
    REMOTE_PORT="${REMOTE_PORT:-22}"
    RETAIN_DAILY="${RETAIN_DAILY:-7}"
    RETAIN_WEEKLY="${RETAIN_WEEKLY:-4}"
    RETAIN_MONTHLY="${RETAIN_MONTHLY:-3}"
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-3}"
    WEBHOOK_TYPE="${WEBHOOK_TYPE:-discord}"

    return 0
}

# Load per-service .backup.conf
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

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        log_info "Loaded config: $config_file"
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
    for var in $(compgen -v | grep -E '^DB_[0-9]+_'); do
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

        local container="${!container_var}"
        [[ -z "$container" ]] && break

        local db_type="${!type_var}"
        local db_names="${!names_var}"

        if [[ -z "$db_type" ]]; then
            log_warn "DB_${i}_TYPE not set for container $container, skipping"
            ((i++))
            continue
        fi

        echo "${container}|${db_type}|${db_names}"
        ((i++))
    done
}

# Build tar exclude arguments from the EXCLUDE config value.
# Usage: build_exclude_args "$EXCLUDE"
# Outputs one --exclude=PATTERN per line
build_exclude_args() {
    local exclude_str="$1"
    [[ -z "$exclude_str" ]] && return

    local IFS=','
    for pattern in $exclude_str; do
        pattern="$(echo "$pattern" | xargs)"  # trim whitespace
        [[ -n "$pattern" ]] && echo "--exclude=$pattern"
    done
}

# Discover docker-compose services under the source directory.
# Prints one service directory path per line.
discover_services() {
    local source_dir="$1"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Source directory does not exist: $source_dir"
        return 1
    fi

    local found=0
    for dir in "$source_dir"/*/; do
        [[ ! -d "$dir" ]] && continue
        if [[ -f "$dir/docker-compose.yml" ]] || [[ -f "$dir/docker-compose.yaml" ]] || [[ -f "$dir/compose.yml" ]] || [[ -f "$dir/compose.yaml" ]]; then
            echo "${dir%/}"
            ((found++))
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_warn "No docker-compose services found in $source_dir"
    fi

    return 0
}
