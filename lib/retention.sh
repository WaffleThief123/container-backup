#!/usr/bin/env bash
# retention.sh - GFS (Grandfather-Father-Son) retention pruning

# Compute ISO day of week (1=Mon..7=Sun) for a YYYY-MM-DD date string.
# Uses Tomohiko Sakamoto's algorithm (pure arithmetic, no external commands).
# Usage: day_of_week "2026-02-12"  => 4 (Thursday)
day_of_week() {
    local y m d
    y="${1%%-*}"
    m="$(echo "$1" | cut -d- -f2)"
    d="${1##*-}"
    # Strip leading zeros for arithmetic
    y=$((10#$y)); m=$((10#$m)); d=$((10#$d))

    local -a t=(0 3 2 5 0 3 5 1 4 6 2 4)
    if (( m < 3 )); then
        ((y--))
    fi
    local dow=$(( (y + y/4 - y/100 + y/400 + t[m-1] + d) % 7 ))
    # Sakamoto returns 0=Sun,1=Mon..6=Sat; convert to ISO 1=Mon..7=Sun
    if (( dow == 0 )); then
        echo 7
    else
        echo "$dow"
    fi
}

# Apply GFS retention policy on the local backup directory.
# Naming convention: servicename-YYYY-MM-DD_HHMMSS.tar.zst.age
# GFS decisions are based on the date portion (YYYY-MM-DD) only.
# Usage: apply_retention
apply_retention() {
    local today
    today="$(date +%Y-%m-%d)"

    log_info "Applying GFS retention policy (daily=$RETAIN_DAILY, weekly=$RETAIN_WEEKLY, monthly=$RETAIN_MONTHLY)"

    # Get list of all backup files in local BACKUP_DIR
    local local_files
    local_files="$(ls -1 "${BACKUP_DIR}/" 2>/dev/null | grep '\.tar\.zst\.age$')"

    if [[ -z "$local_files" ]]; then
        log_info "No backups found in $BACKUP_DIR, nothing to prune"
        return 0
    fi

    # Extract unique service names
    local services
    services="$(echo "$local_files" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{6\}\.tar\.zst\.age$//' | sort -u)"

    local total_pruned=0

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        local pruned
        pruned="$(prune_service_backups "$service" "$local_files")"
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

    # Build the set of dates to keep (keyed on YYYY-MM-DD only)
    local -A keep_dates

    # Extract dates from filenames (strip time portion for GFS decisions)
    local dates
    dates="$(echo "$service_files" | sed "s/^${service}-//;s/_[0-9]\{6\}\.tar\.zst\.age$//" | sort -ru)"

    # Daily: keep the most recent N unique dates
    local daily_count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if [[ $daily_count -lt $RETAIN_DAILY ]]; then
            keep_dates["$d"]="daily"
            daily_count=$((daily_count + 1))
        fi
    done <<< "$dates"

    # Weekly: keep the most recent N Sundays (day of week = 7)
    local weekly_count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local dow
        dow="$(day_of_week "$d")" # 7 = Sunday
        if [[ "$dow" == "7" ]] && [[ $weekly_count -lt $RETAIN_WEEKLY ]]; then
            keep_dates["$d"]="${keep_dates[$d]:+${keep_dates[$d]}+}weekly"
            weekly_count=$((weekly_count + 1))
        fi
    done <<< "$dates"

    # Monthly: keep 1st of month for the most recent N months
    local monthly_count=0
    local seen_months=""
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local day_of_month
        day_of_month="$(echo "$d" | cut -d- -f3)"
        local month_key
        month_key="$(echo "$d" | cut -d- -f1-2)"

        if [[ "$day_of_month" == "01" ]] && [[ ! "$seen_months" == *"$month_key"* ]] && [[ $monthly_count -lt $RETAIN_MONTHLY ]]; then
            keep_dates["$d"]="${keep_dates[$d]:+${keep_dates[$d]}+}monthly"
            seen_months="$seen_months $month_key"
            monthly_count=$((monthly_count + 1))
        fi
    done <<< "$dates"

    # Determine which files to delete (extract date portion from filename)
    local pruned=0
    local -a to_delete=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local file_date
        file_date="$(echo "$f" | sed "s/^${service}-//;s/_[0-9]\{6\}\.tar\.zst\.age$//")"

        if [[ -z "${keep_dates[$file_date]+_}" ]]; then
            to_delete+=("$f")
            pruned=$((pruned + 1))
        fi
    done <<< "$service_files"

    # Delete files locally
    if [[ ${#to_delete[@]} -gt 0 ]]; then
        log_info "Pruning $service: removing ${#to_delete[@]} old backup(s)"
        for f in "${to_delete[@]}"; do
            log_info "  Removing: $f"
            rm -f "${BACKUP_DIR}/$f"
        done
    fi

    echo "$pruned"
}
