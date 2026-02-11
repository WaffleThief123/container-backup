#!/usr/bin/env bash
# archive.sh - tar + zstd archive creation

# Create a compressed archive of a service directory.
# Usage: create_archive /opt/docker/myapp /var/tmp/backups myapp-2026-02-11.tar.zst
create_archive() {
    local service_dir="$1"
    local staging_dir="$2"
    local archive_name="$3"
    local archive_path="$staging_dir/$archive_name"

    mkdir -p "$staging_dir"

    # Build exclude arguments
    local -a exclude_args=()
    if [[ -n "$EXCLUDE" ]]; then
        while IFS= read -r arg; do
            exclude_args+=("$arg")
        done < <(build_exclude_args "$EXCLUDE")
    fi

    # Always exclude the _dumps marker after they're included in the archive
    # (we want dumps IN the archive, just not leftover from previous runs)

    local parent_dir
    parent_dir="$(dirname "$service_dir")"
    local base_name
    base_name="$(basename "$service_dir")"

    log_info "Creating archive: $archive_name"
    log_info "  Source: $service_dir"
    log_info "  Compression: zstd level $COMPRESSION_LEVEL"

    local start_time
    start_time=$(date +%s)

    if tar -C "$parent_dir" \
        -I "zstd -T0 -${COMPRESSION_LEVEL}" \
        "${exclude_args[@]}" \
        -cf "$archive_path" \
        "$base_name" 2>/tmp/tar_err; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size
        size="$(du -h "$archive_path" | cut -f1)"
        local raw_size
        raw_size="$(du -sh "$service_dir" | cut -f1)"

        log_info "  Archive created: $size (from $raw_size) in ${duration}s"
        echo "$archive_path"
        return 0
    else
        log_error "  Failed to create archive: $(cat /tmp/tar_err)"
        rm -f "$archive_path"
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
