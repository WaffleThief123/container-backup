#!/usr/bin/env bash
# notify.sh - Webhook notifications + journal logging

# Send a backup summary notification.
# Usage: send_notification success|failure "$summary_message" "$details"
send_notification() {
    local status="$1"   # success | failure
    local summary="$2"
    local details="$3"

    # Always log to journal
    local priority="info"
    [[ "$status" == "failure" ]] && priority="err"
    log_info "Notification [$status]: $summary"

    # Send webhook if configured
    if [[ -n "$WEBHOOK_URL" ]]; then
        case "$WEBHOOK_TYPE" in
            discord)
                send_discord "$status" "$summary" "$details"
                ;;
            slack)
                send_slack "$status" "$summary" "$details"
                ;;
            telegram)
                send_telegram "$status" "$summary" "$details"
                ;;
            *)
                log_warn "Unknown WEBHOOK_TYPE: $WEBHOOK_TYPE"
                ;;
        esac
    fi
}

# Send Discord webhook notification.
send_discord() {
    local status="$1"
    local summary="$2"
    local details="$3"

    local color=3066993   # green
    [[ "$status" == "failure" ]] && color=15158332  # red

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Truncate details to fit Discord's 4096 char limit for embed description
    if [[ ${#details} -gt 3900 ]]; then
        details="${details:0:3900}... (truncated)"
    fi

    local payload
    payload="$(jq -nc \
        --arg title "Docker Backup: ${status^}" \
        --arg desc "$details" \
        --argjson color "$color" \
        --arg footer "$summary" \
        --arg ts "$timestamp" \
        '{
            embeds: [{
                title: $title,
                description: $desc,
                color: $color,
                footer: { text: $footer },
                timestamp: $ts
            }]
        }'
    )"

    local curl_err
    if ! curl_err="$(curl -sS -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" 2>&1 >/dev/null)"; then
        log_warn "Discord webhook failed: $curl_err"
    fi
}

# Send Slack webhook notification.
send_slack() {
    local status="$1"
    local summary="$2"
    local details="$3"

    local emoji=":white_check_mark:"
    [[ "$status" == "failure" ]] && emoji=":x:"

    # Truncate details for Slack's limits
    if [[ ${#details} -gt 2900 ]]; then
        details="${details:0:2900}... (truncated)"
    fi

    local payload
    payload="$(jq -nc \
        --arg emoji "$emoji" \
        --arg summary "$summary" \
        --arg details "$details" \
        '{
            blocks: [
                {
                    type: "header",
                    text: {
                        type: "plain_text",
                        text: ($emoji + " Docker Backup"),
                        emoji: true
                    }
                },
                {
                    type: "section",
                    text: {
                        type: "mrkdwn",
                        text: $summary
                    }
                },
                {
                    type: "section",
                    text: {
                        type: "mrkdwn",
                        text: ("```" + $details + "```")
                    }
                }
            ]
        }'
    )"

    local curl_err
    if ! curl_err="$(curl -sS -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" 2>&1 >/dev/null)"; then
        log_warn "Slack webhook failed: $curl_err"
    fi
}

# Send Telegram notification via Bot API.
# WEBHOOK_URL should be the bot token, TELEGRAM_CHAT_ID the target chat.
send_telegram() {
    local status="$1"
    local summary="$2"
    local details="$3"

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        log_warn "TELEGRAM_CHAT_ID not set, skipping Telegram notification"
        return
    fi

    local icon="✅"
    [[ "$status" == "failure" ]] && icon="❌"

    # Truncate details for Telegram's 4096 char message limit
    if [[ ${#details} -gt 3500 ]]; then
        details="${details:0:3500}... (truncated)"
    fi

    local text="${icon} <b>Docker Backup: ${status^}</b>

${summary}

<pre>${details}</pre>"

    local api_url="https://api.telegram.org/bot${WEBHOOK_URL}/sendMessage"

    local payload
    payload="$(jq -nc \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$text" \
        '{
            chat_id: $chat_id,
            text: $text,
            parse_mode: "HTML",
            disable_web_page_preview: true
        }'
    )"

    local curl_err
    if ! curl_err="$(curl -sS -H "Content-Type: application/json" \
        -d "$payload" \
        "$api_url" 2>&1 >/dev/null)"; then
        log_warn "Telegram notification failed: $curl_err"
    fi
}

# Build a summary from the results collected during backup.
# Usage: build_summary
# Reads from global arrays: BACKUP_RESULTS, BACKUP_ERRORS
build_summary() {
    local total_services=${#BACKUP_RESULTS[@]}
    local total_errors=${#BACKUP_ERRORS[@]}
    local total_size="$TOTAL_BACKUP_SIZE"
    local duration="$TOTAL_DURATION"

    local status="success"
    [[ $total_errors -gt 0 ]] && status="failure"

    local summary="Backed up ${total_services} service(s) in ${duration}s, total size: ${total_size}"
    if [[ $total_errors -gt 0 ]]; then
        summary+=", ${total_errors} error(s)"
    fi

    local details=""
    details+="Services:\n"
    for result in "${BACKUP_RESULTS[@]}"; do
        details+="  $result\n"
    done

    if [[ $total_errors -gt 0 ]]; then
        details+="\nErrors:\n"
        for err in "${BACKUP_ERRORS[@]}"; do
            details+="  $err\n"
        done
    fi

    # Use printf to interpret \n
    local formatted_details
    formatted_details="$(printf '%b' "$details")"

    send_notification "$status" "$summary" "$formatted_details"
}
