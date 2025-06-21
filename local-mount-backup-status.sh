#!/bin/bash

# ====================================================================================
#
#          FILE: local-mount-backup-status.sh (v2, detailed output)
#
#         USAGE: ./local-mount-backup-status.sh
#
#   DESCRIPTION: Checks and reports the detailed status of the main backup script.
#                Parses log files to provide timing and status information.
#
# ====================================================================================

# --- Configuration ---
source /srv/scripts/local-mount-backup.conf

# --- Helper Functions ---
format_duration() {
    local duration=$1
    if (( duration < 0 )); then duration=0; fi
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    printf "%d minutes, %d seconds" $minutes $seconds
}

format_time_ago() {
    local seconds_ago=$1
    if (( seconds_ago < 60 )); then echo "${seconds_ago} seconds ago"
    elif (( seconds_ago < 3600 )); then echo "$((seconds_ago / 60)) minutes ago"
    elif (( seconds_ago < 86400 )); then echo "$((seconds_ago / 3600)) hours ago"
    elif (( seconds_ago < 2592000 )); then echo "$((seconds_ago / 86400)) days ago"
    elif (( seconds_ago < 31536000 )); then echo "$((seconds_ago / 2592000)) months ago"
    else echo "$((seconds_ago / 31536000)) years ago"; fi
}

# --- Main Script Logic ---
printf "%-28s | %s\n" "Report generated" "$(date)"
echo "----------------------------------------------------------------------"

LATEST_LOG=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -n 1)

if [ -e "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
        # ---- SCRIPT IS CURRENTLY RUNNING ----
        START_TIMESTAMP=$(stat -c %Y "$LOCK_FILE")
        NOW_TIMESTAMP=$(date +%s)
        DURATION_SECONDS=$((NOW_TIMESTAMP - START_TIMESTAMP))

        printf "%-28s | %s\n" "Status" "🟢 RUNNING"
        printf "%-28s | %s\n" "Process ID (PID)" "$PID"
        printf "%-28s | %s\n" "Started at" "$(date -d "@$START_TIMESTAMP" +"%Y-%m-%d %H:%M:%S")"
        printf "%-28s | %s\n" "Running for" "$(format_duration $DURATION_SECONDS)"

        if [ -n "$LATEST_LOG" ]; then
            # FIX: Added -e to grep to handle the leading hyphen in the pattern.
            if grep -q -e "✅ Rsync completed successfully." "$LATEST_LOG"; then
                LAST_START_STRING=$(grep -e "--- Backup Started:" "$LATEST_LOG" | sed 's/.*: //')
                LAST_END_STRING=$(grep -e "--- Backup Finished:" "$LATEST_LOG" | sed 's/.*: //')
                if [ -n "$LAST_START_STRING" ] && [ -n "$LAST_END_STRING" ]; then
                    LAST_START_TS=$(date -d "$LAST_START_STRING" +%s)
                    LAST_END_TS=$(date -d "$LAST_END_STRING" +%s)
                    LAST_DURATION=$(format_duration $((LAST_END_TS - LAST_START_TS)))
                    printf "%-28s | %s\n" "Last successful backup took" "$LAST_DURATION"
                fi
            fi
        fi
    else
        printf "%-28s | %s\n" "Status" "🟡 WARNING: Stale lock file found"
        printf "%-28s | %s\n" "Info" "PID $PID is not running. Backup is NOT active."
    fi
else
    # ---- SCRIPT IS NOT RUNNING ----
    printf "%-28s | %s\n" "Status" "⚪ NOT RUNNING"

    if [ -z "$LATEST_LOG" ]; then
        printf "%-28s | %s\n" "Last backup" "Never ran (no log files found)."
    else
        # FIX: Added -e to grep to handle the leading hyphen in the pattern.
        LAST_START_STRING=$(grep -e "--- Backup Started:" "$LATEST_LOG" | sed 's/.*: //')
        LAST_END_STRING=$(grep -e "--- Backup Finished:" "$LATEST_LOG" | sed 's/.*: //')

        if [ -n "$LAST_START_STRING" ] && [ -n "$LAST_END_STRING" ]; then
            if grep -q -e "✅ Rsync completed successfully." "$LATEST_LOG"; then
                LAST_STATUS="✅ SUCCESS"
            else
                LAST_STATUS="❌ FAILURE"
            fi

            LAST_START_TS=$(date -d "$LAST_START_STRING" +%s)
            LAST_END_TS=$(date -d "$LAST_END_STRING" +%s)

            printf "%-28s | %s\n" "Last backup status" "$LAST_STATUS"
            printf "%-28s | %s\n" "Last backup started" "$(date -d "@$LAST_START_TS" +"%Y-%m-%d %H:%M:%S")"
            printf "%-28s | %s\n" "Last backup ended" "$(date -d "@$LAST_END_TS" +"%Y-%m-%d %H:%M:%S")"
            printf "%-28s | %s\n" "Last backup ran" "$(format_time_ago $(( $(date +%s) - LAST_END_TS)))"
            printf "%-28s | %s\n" "Last backup duration" "$(format_duration $((LAST_END_TS - LAST_START_TS)))"
        else
            printf "%-28s | %s\n" "Last backup status" "⚠️ UNKNOWN (Incomplete log file)"
            printf "%-28s | %s\n" "Log file" "$LATEST_LOG"
        fi
    fi
fi
echo "----------------------------------------------------------------------"