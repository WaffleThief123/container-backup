#!/usr/bin/env bash
# retention.sh - GFS (Grandfather-Father-Son) retention pruning

# Apply GFS retention policy on the remote server.
# Naming convention: servicename-YYYY-MM-DD.tar.zst.age
# Usage: apply_retention
apply_retention() {
    local today
    today="$(date +%Y-%m-%d)"

    log_info "Applying GFS retention policy (daily=$RETAIN_DAILY, weekly=$RETAIN_WEEKLY, monthly=$RETAIN_MONTHLY)"

    # Get list of all backup files on remote
    local remote_files
    remote_files="$($(ssh_cmd) "${REMOTE_USER}@${REMOTE_HOST}" \
        "ls -1 '${REMOTE_PATH}/' 2>/dev/null" 2>/dev/null | grep '\.tar\.zst\.age$')"

    if [[ -z "$remote_files" ]]; then
        log_info "No backups found on remote, nothing to prune"
        return 0
    fi

    # Extract unique service names
    local services
    services="$(echo "$remote_files" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\.tar\.zst\.age$//' | sort -u)"

    local total_pruned=0

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        local pruned
        pruned="$(prune_service_backups "$service" "$remote_files")"
        total_pruned=$((total_pruned + pruned))
    done <<< "$services"

    log_info "Retention complete: pruned $total_pruned backup(s)"
    return 0
}

# Prune backups for a single service according to GFS policy.
# Usage: prune_service_backups servicename "$all_files"
# Prints number of files pruned.
prune_service_backups() {
    local service="$1"
    local all_files="$2"

    # Get files for this service, extract dates, sort newest first
    local service_files
    service_files="$(echo "$all_files" | grep "^${service}-[0-9]" | sort -r)"

    if [[ -z "$service_files" ]]; then
        echo 0
        return
    fi

    # Build the set of dates to keep
    local -A keep_dates

    # Extract all dates for this service
    local dates
    dates="$(echo "$service_files" | sed "s/^${service}-//;s/\.tar\.zst\.age$//" | sort -r)"

    # Daily: keep the most recent N
    local daily_count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if [[ $daily_count -lt $RETAIN_DAILY ]]; then
            keep_dates["$d"]="daily"
            ((daily_count++))
        fi
    done <<< "$dates"

    # Weekly: keep the most recent N Sundays (day of week = 0)
    local weekly_count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local dow
        dow="$(date -d "$d" +%u 2>/dev/null)" # 7 = Sunday
        if [[ "$dow" == "7" ]] && [[ $weekly_count -lt $RETAIN_WEEKLY ]]; then
            keep_dates["$d"]="${keep_dates[$d]:+${keep_dates[$d]}+}weekly"
            ((weekly_count++))
        fi
    done <<< "$dates"

    # Monthly: keep 1st of month for the most recent N months
    local monthly_count=0
    local seen_months=""
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local day_of_month
        day_of_month="$(date -d "$d" +%d 2>/dev/null)"
        local month_key
        month_key="$(date -d "$d" +%Y-%m 2>/dev/null)"

        if [[ "$day_of_month" == "01" ]] && [[ ! "$seen_months" == *"$month_key"* ]] && [[ $monthly_count -lt $RETAIN_MONTHLY ]]; then
            keep_dates["$d"]="${keep_dates[$d]:+${keep_dates[$d]}+}monthly"
            seen_months="$seen_months $month_key"
            ((monthly_count++))
        fi
    done <<< "$dates"

    # Determine which files to delete
    local pruned=0
    local -a to_delete=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local file_date
        file_date="$(echo "$f" | sed "s/^${service}-//;s/\.tar\.zst\.age$//")"

        if [[ -z "${keep_dates[$file_date]+_}" ]]; then
            to_delete+=("$f")
            ((pruned++))
        fi
    done <<< "$service_files"

    # Delete files on remote
    if [[ ${#to_delete[@]} -gt 0 ]]; then
        local delete_cmd="cd '${REMOTE_PATH}' && rm -f"
        for f in "${to_delete[@]}"; do
            delete_cmd+=" '$f'"
        done

        log_info "Pruning $service: removing ${#to_delete[@]} old backup(s)"
        for f in "${to_delete[@]}"; do
            log_info "  Removing: $f"
        done

        $(ssh_cmd) "${REMOTE_USER}@${REMOTE_HOST}" "$delete_cmd" 2>/dev/null
    fi

    echo "$pruned"
}
