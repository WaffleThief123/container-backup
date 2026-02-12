#!/usr/bin/env bash
# archive.sh - tar + zstd archive creation on production server

# Create a compressed archive of a service directory on production.
# Archive is written to PRODUCTION_STAGING_DIR on the remote side.
# Usage: create_archive /opt/docker/myapp myapp-2026-02-11.tar.zst
# Returns the archive filename (not a local path — file is on production).
create_archive() {
    local service_dir="$1"
    local archive_name="$2"
    local archive_path="${PRODUCTION_STAGING_DIR}/${archive_name}"

    # Build exclude arguments as a flat string for SSH
    local exclude_str=""
    if [[ -n "$EXCLUDE" ]]; then
        local pattern
        for pattern in ${EXCLUDE//,/ }; do
            pattern="$(echo "$pattern" | xargs)"
            [[ -n "$pattern" ]] && exclude_str+=" --exclude=$pattern"
        done
    fi

    local parent_dir
    parent_dir="$(dirname "$service_dir")"
    local base_name
    base_name="$(basename "$service_dir")"

    log_info "Creating archive: $archive_name (on production)"
    log_info "  Source: $service_dir"
    log_info "  Compression: zstd level $COMPRESSION_LEVEL"

    local start_time
    start_time=$(date +%s)

    local tar_err
    if tar_err="$(prod_ssh "tar -C '$parent_dir' -I 'zstd -T0 -${COMPRESSION_LEVEL}'${exclude_str} -cf '$archive_path' '$base_name'" 2>&1)"; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        local size
        size="$(prod_ssh "du -h '$archive_path' | cut -f1")"
        local raw_size
        raw_size="$(prod_ssh "du -sh '$service_dir' | cut -f1")"

        log_info "  Archive created: $size (from $raw_size) in ${duration}s"
        echo "$archive_name"
        return 0
    else
        log_error "  Failed to create archive: $tar_err"
        prod_ssh "rm -f '$archive_path'" 2>/dev/null
        return 1
    fi
}

# Generate archive filename for a service and date.
# Usage: archive_filename myapp 2026-02-11
# Output: myapp-2026-02-11.tar.zst
archive_filename() {
    local service_name="$1"
    local date_str="${2:-$(date +%Y-%m-%d)}"
    echo "${service_name}-${date_str}.tar.zst"
}
