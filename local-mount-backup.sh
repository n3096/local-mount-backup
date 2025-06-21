#!/bin/bash

# ====================================================================================
#
#          FILE: local-mount-backup.sh (v7, with config validation)
#
#         USAGE: sudo ./local-mount-backup.sh {start|status|finish|help}
#
# ====================================================================================

# --- DYNAMIC CONFIGURATION LOADER ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT_BASENAME=$(basename -- "$0" .sh)
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_BASENAME}.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ ERROR: Configuration file not found at '$CONFIG_FILE'." >&2
    echo "It must be in the same directory as the script and have the same name, with a .conf extension." >&2
    exit 1
fi

# --- HELPER & VALIDATION FUNCTIONS ---
validate_config() {
    local error_found=0
    echo "INFO: Validating configuration..."

    if [ -z "$DEVICE_NAME" ]; then
        echo "❌ CONFIG ERROR: 'DEVICE_NAME' is not set in '$CONFIG_FILE'." >&2
        error_found=1
    fi

    if [ -z "$MOUNT_POINT" ]; then
        echo "❌ CONFIG ERROR: 'MOUNT_POINT' is not set in '$CONFIG_FILE'." >&2
        error_found=1
    # Check if MOUNT_POINT is an absolute path
    elif [[ "$MOUNT_POINT" != /* ]]; then
        echo "❌ CONFIG ERROR: 'MOUNT_POINT' must be an absolute path (e.g., /mnt/backup-usb)." >&2
        error_found=1
    fi

    if [ -z "$DRIVE_UUID" ]; then
        echo "❌ CONFIG ERROR: 'DRIVE_UUID' is not set in '$CONFIG_FILE'." >&2
        error_found=1
    fi

    # Check if the SOURCE_DIRS array is empty.
    if [ ${#SOURCE_DIRS[@]} -eq 0 ]; then
        echo "❌ CONFIG ERROR: 'SOURCE_DIRS' array is empty in '$CONFIG_FILE'. Nothing to back up." >&2
        error_found=1
    fi

    if [ -z "$RSYNC_OPTS" ]; then
        echo "❌ CONFIG ERROR: 'RSYNC_OPTS' is not set in '$CONFIG_FILE'." >&2
        error_found=1
    fi

    # If any error was found, abort the script.
    if [ $error_found -ne 0 ]; then
        echo "FATAL: Configuration validation failed. Please correct your config file. Aborting." >&2
        exit 1
    fi

    echo "✅ Configuration seems valid."
}

send_discord_notification() {
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        return 0
    fi

    if ! command -v curl &> /dev/null; then
        echo "WARN: 'curl' command not found, cannot send Discord notification." >&2
        return 1
    fi

    local title="$1"
    local message="$2"
    local color_code="$3" # "green", "red", "blue", "orange"
    local discord_color

    case "$color_code" in
        green)  discord_color=5814784  ;;
        red)    discord_color=15746887 ;;
        blue)   discord_color=3447003  ;;
        orange) discord_color=15105570 ;;
        *)      discord_color=10070709 ;;
    esac

    local hostname
    hostname=$(hostname)

    local json_payload
    json_payload=$(printf '{
      "username": "%s",
      "embeds": [{
        "title": "%s",
        "description": "%s",
        "color": %d,
        "footer": { "text": "Hostname: %s" },
        "timestamp": "%sT%s"
      }]
    }' "$DEVICE_NAME" "$title" "$message" "$discord_color" "$hostname" "$(date -u +%Y-%m-%d)" "$(date -u +%H:%M:%S.%3N)")

    curl -H "Content-Type: application/json" -X POST -d "$json_payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1
}

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
    else echo "$((seconds_ago / 86400)) days ago"; fi
}

show_help() {
    echo "Usage: $(basename "$0") {start|status|finish|help}"
    echo "  start   - Starts the backup process in the background."
    echo "  status  - Shows the current status of the backup process."
    echo "  finish  - Safely unmounts the backup drive if no backup is running."
    echo "  help    - Displays this help message."
}

validate_config

# --- NON-CONFIGURABLE DERIVED VARIABLES ---
BACKUP_SCRIPT_NAME=$(basename -- "$0")
DEST_DIR="${MOUNT_POINT}/${DEVICE_NAME}/backup"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/backup_$(date +%Y%m%d-%H%M%S).log"
LOCK_DIR="${SCRIPT_DIR}/lock"
LOCK_FILE="${LOCK_DIR}/${BACKUP_SCRIPT_NAME}.pid"

# --- CORE LOGIC FUNCTIONS ---
do_start_launcher() {
    if [ "$EUID" -ne 0 ]; then
      echo "Error: 'start' command must be run with sudo." >&2
      exit 1
    fi
    mkdir -p "$LOCK_DIR"

    if [ -e "$LOCK_FILE" ]; then
        local OTHER_PID
        OTHER_PID=$(cat "$LOCK_FILE")
        if ps -p "$OTHER_PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
            echo "❌ ERROR: Backup script appears to be running with PID: $OTHER_PID. Aborting." >&2
            exit 1
        else
            echo "WARN: Found a stale lock file. Removing it before starting."
            rm -f "$LOCK_FILE"
        fi
    fi

    echo "Starting backup process in the background..."
    echo "Logs are written to: $LOG_DIR"
    nohup "$0" --background > /dev/null 2>&1 &
    echo "Backup job submitted. Check status with: $BACKUP_SCRIPT_NAME status"
}

do_run_backup() {
    local backup_successful=false

    cleanup() {
        local exit_code=${1:-$?}
        if [[ "$backup_successful" == "false" ]] && [[ "$exit_code" -ne 0 ]]; then
            send_discord_notification "Backup Aborted / Failed" "The backup process was terminated unexpectedly (Exit Code: $exit_code)." "orange"
        fi
        rm -f "$LOCK_FILE"
    }

    trap 'cleanup' EXIT
    trap 'echo "WARN: Interrupt signal caught, cleaning up..."; cleanup 130' INT
    trap 'echo "WARN: Terminate signal caught, cleaning up..."; cleanup 143' TERM

    echo "$$" > "$LOCK_FILE"
    mkdir -p "$LOG_DIR"
    local LOG_FILE="${LOG_DIR}/backup_$(date +%Y%m%d-%H%M%S).log"

    send_discord_notification "Backup Started" "Backup process for device '$DEVICE_NAME' has been initiated." "blue"

    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "INFO: Mount point not mounted. Attempting to mount..." | tee -a "$LOG_FILE"
        mkdir -p "$MOUNT_POINT"
        mount UUID="$DRIVE_UUID" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            local mount_error="❌ ERROR: Failed to mount drive with UUID '$DRIVE_UUID'. Aborting."
            echo "$mount_error" | tee -a "$LOG_FILE" >&2
            send_discord_notification "Backup Failure" "$mount_error" "red"
            exit 1
        fi
    fi

    mkdir -p "$DEST_DIR"
    if [ ! -w "$DEST_DIR" ]; then
        local perm_error="❌ ERROR: Destination directory '$DEST_DIR' not writable. Aborting."
        echo "$perm_error" | tee -a "$LOG_FILE" >&2
        send_discord_notification "Backup Failure" "$perm_error" "red"
        exit 1
    fi

    echo "--- Backup Started: $(date) ---" | tee -a "$LOG_FILE"

    local start_time
    start_time=$(date +%s)

    rsync $RSYNC_OPTS "${SOURCE_DIRS[@]}" "$DEST_DIR" >> "$LOG_FILE" 2>&1
    local rsync_exit_code=$?

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "--- Backup Finished: $(date) ---" | tee -a "$LOG_FILE"

    if [ $rsync_exit_code -eq 0 ]; then
        local success_msg="✅ Rsync completed successfully in $(format_duration "$duration")."
        echo "$success_msg" | tee -a "$LOG_FILE"
        send_discord_notification "Backup Success" "$success_msg" "green"
        backup_successful=true
    else
        local rsync_error_msg="❌ ERROR: Rsync failed with exit code $rsync_exit_code after $(format_duration "$duration")."
        echo "$rsync_error_msg" | tee -a "$LOG_FILE"
        send_discord_notification "Backup Failure" "$rsync_error_msg" "red"
    fi

    exit $rsync_exit_code
}

do_show_status() {
    printf "%-28s | %s\n" "Report generated" "$(date)"
    echo "----------------------------------------------------------------------"
    local LATEST_LOG
    LATEST_LOG=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -n 1)

    if [ -e "$LOCK_FILE" ]; then
        local PID
        PID=$(cat "$LOCK_FILE")
        if ps -p "$PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
            local START_TIMESTAMP DURATION_SECONDS
            START_TIMESTAMP=$(stat -c %Y "$LOCK_FILE")
            DURATION_SECONDS=$(( $(date +%s) - START_TIMESTAMP ))
            printf "%-28s | %s\n" "Status" "🟢 RUNNING"
            printf "%-28s | %s\n" "Process ID (PID)" "$PID"
            printf "%-28s | %s\n" "Started at" "$(date -d "@$START_TIMESTAMP" +"%Y-%m-%d %H:%M:%S")"
            printf "%-28s | %s\n" "Running for" "$(format_duration $DURATION_SECONDS)"
        else
            printf "%-28s | %s\n" "Status" "🟡 WARNING: Stale lock file found"
            printf "%-28s | %s\n" "Info" "PID $PID is not running. Backup is NOT active."
        fi
    else
        printf "%-28s | %s\n" "Status" "⚪ NOT RUNNING"
        if [ -z "$LATEST_LOG" ]; then
            printf "%-28s | %s\n" "Last backup" "Never ran (no log files found)."
        else
            local LAST_START_STRING LAST_END_STRING LAST_STATUS LAST_START_TS LAST_END_TS
            LAST_START_STRING=$(grep -e "--- Backup Started:" "$LATEST_LOG" | sed 's/.*: //')
            LAST_END_STRING=$(grep -e "--- Backup Finished:" "$LATEST_LOG" | sed 's/.*: //')
            if [ -n "$LAST_START_STRING" ] && [ -n "$LAST_END_STRING" ]; then
                grep -q -e "✅ Rsync completed successfully." "$LATEST_LOG" && LAST_STATUS="✅ SUCCESS" || LAST_STATUS="❌ FAILURE"
                LAST_START_TS=$(date -d "$LAST_START_STRING" +%s)
                LAST_END_TS=$(date -d "$LAST_END_STRING" +%s)
                printf "%-28s | %s\n" "Last backup status" "$LAST_STATUS"
                printf "%-28s | %s\n" "Last backup ended" "$(date -d "@$LAST_END_TS" +"%Y-%m-%d %H:%M:%S")"
                printf "%-28s | %s\n" "Last backup ran" "$(format_time_ago $(( $(date +%s) - LAST_END_TS)))"
                printf "%-28s | %s\n" "Last backup duration" "$(format_duration $((LAST_END_TS - LAST_START_TS)))"
            else
                printf "%-28s | %s\n" "Last backup status" "⚠️ UNKNOWN (Incomplete log file)"
            fi
        fi
    fi
    echo "----------------------------------------------------------------------"
    echo "Backup History (last 10 entries):"
    local all_logs
    all_logs=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -n 10)

    if [ -z "$all_logs" ]; then
        echo "  No history found."
    else
        while IFS= read -r log_file; do
            local start_string end_string status start_ts end_ts duration
            start_string=$(grep -e "--- Backup Started:" "$log_file" | sed 's/.*: //')
            end_string=$(grep -e "--- Backup Finished:" "$log_file" | sed 's/.*: //')

            if [ -n "$start_string" ] && [ -n "$end_string" ]; then
                start_ts=$(date -d "$start_string" +%s)
                end_ts=$(date -d "$end_string" +%s)
                duration=$((end_ts - start_ts))

                if grep -q "✅ Rsync completed successfully." "$log_file"; then
                    status="✅ SUCCESS"
                else
                    status="❌ FAILURE"
                fi

                printf "  %s (%s; %s)\n" \
                    "$(date -d "@$start_ts" +"%Y-%m-%d %H:%M:%S")" \
                    "$status" \
                    "$(format_duration "$duration")"
            else
                local file_timestamp=$(stat -c %Y "$log_file")
                printf "  %s (⚠️ INCOMPLETE LOG)\n" "$(date -d "@$file_timestamp" +"%Y-%m-%d %H:%M:%S")"
            fi
        done <<< "$all_logs"
    fi
    echo "----------------------------------------------------------------------"
}

do_finish_unmount() {
    if [ "$EUID" -ne 0 ]; then
      echo "Error: 'finish' command must be run with sudo." >&2
      exit 1
    fi
    echo "Attempting to safely unmount the backup drive at '$MOUNT_POINT'..."
    if [ -e "$LOCK_FILE" ]; then
        local PID
        PID=$(cat "$LOCK_FILE")
        if ps -p "$PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
            echo "❌ ERROR: Cannot unmount. The backup script is currently running with PID: $PID." >&2
            exit 1
        fi
    fi
    if mountpoint -q "$MOUNT_POINT"; then
        echo "INFO: Backup is not running. Proceeding with unmount..."
        umount "$MOUNT_POINT"
        if [ $? -eq 0 ]; then
            echo "✅ SUCCESS: Drive at '$MOUNT_POINT' has been unmounted successfully."
        else
            echo "❌ ERROR: 'umount' command failed. The drive might be in use by another process." >&2
            exit 1
        fi
    else
        echo "INFO: Drive at '$MOUNT_POINT' is already unmounted. Nothing to do."
    fi
}

# --- MAIN CONTROLLER ---
if [ -z "$1" ]; then
    show_help
    exit 0
fi

case "$1" in
    start)
        do_start_launcher
        ;;
    status)
        do_show_status
        ;;
    finish)
        do_finish_unmount
        ;;
    help|--help|-h)
        show_help
        ;;
    --background)
        do_run_backup
        ;;
    *)
        echo "Error: Invalid command '$1'" >&2
        show_help
        exit 1
        ;;
esac

exit 0