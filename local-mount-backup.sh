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

# NEW: This function validates the settings loaded from the .conf file.
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

# --- Call the validation function right after sourcing the config ---
validate_config

# --- NON-CONFIGURABLE DERIVED VARIABLES ---
DEST_DIR="${MOUNT_POINT}/${DEVICE_NAME}/backup"
LOG_DIR="${SCRIPT_DIR}/logs"
LOCK_DIR="${SCRIPT_DIR}/lock"
BACKUP_SCRIPT_NAME=$(basename -- "$0")
LOCK_FILE="${LOCK_DIR}/${BACKUP_SCRIPT_NAME}.pid"

# --- CORE LOGIC FUNCTIONS ---
# (The content of these functions remains the same as before)
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
    nohup "$0" --background > /dev/null 2>&1 &
    echo "Backup job submitted. Check status with: $BACKUP_SCRIPT_NAME status"
}

do_run_backup() {
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
    echo "$$" > "$LOCK_FILE"
    mkdir -p "$LOG_DIR"

    if ! mountpoint -q "$MOUNT_POINT"; then
        mount UUID="$DRIVE_UUID" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            echo "❌ ERROR: Failed to mount drive. Aborting." | tee -a "$LOG_FILE" >&2
            exit 1
        fi
    fi

    mkdir -p "$DEST_DIR"
    if [ ! -w "$DEST_DIR" ]; then
        echo "❌ ERROR: Destination directory $DEST_DIR not writable. Aborting." | tee -a "$LOG_FILE" >&2
        exit 1
    fi

    echo "--- Backup Started: $(date) ---" | tee -a "$LOG_FILE"
    rsync $RSYNC_OPTS "${SOURCE_DIRS[@]}" "$DEST_DIR" >> "$LOG_FILE" 2>&1
    RSYNC_EXIT_CODE=$?
    echo "--- Backup Finished: $(date) ---" | tee -a "$LOG_FILE"

    if [ $RSYNC_EXIT_CODE -eq 0 ]; then
      echo "✅ Rsync completed successfully." | tee -a "$LOG_FILE"
    else
      echo "❌ ERROR: Rsync failed with exit code $RSYNC_EXIT_CODE." | tee -a "$LOG_FILE"
    fi
    exit $RSYNC_EXIT_CODE
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