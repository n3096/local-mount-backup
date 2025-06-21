#!/bin/bash

# ====================================================================================
#
#          FILE: local-mount-backup-start.sh (v4, race-condition-fixed)
#
#         USAGE: sudo ./local-mount-backup-start.sh
#
#   DESCRIPTION: A self-detaching, robust, synchronous rsync backup script.
#                Includes a hardened PID lock to prevent race conditions.
#
# ====================================================================================

# --- Configuration ---
source /pfad/zu/ihrer/backup-my-device.conf

# This function defines the main backup workload.
run_backup_workload() {
    # --- Cleanup Trap ---
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
    echo "$$" > "$LOCK_FILE"
    mkdir -p "$LOG_DIR"

    # --- Auto-mount Logic ---
    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "WARN: Destination not mounted. Mounting by UUID..." | tee -a "$LOG_FILE"
        mkdir -p "$MOUNT_POINT"
        mount UUID="$DRIVE_UUID" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            echo "❌ ERROR: Failed to mount drive. Aborting." | tee -a "$LOG_FILE"
            exit 1
        fi
    fi

    # --- Final Destination Check ---
    mkdir -p "$DEST_DIR"
    if [ ! -w "$DEST_DIR" ]; then
        echo "❌ ERROR: Destination directory $DEST_DIR not writable. Aborting." | tee -a "$LOG_FILE"
        exit 1
    fi

    # --- Main Execution (Synchronous Call) ---
    echo "=================================================" | tee -a "$LOG_FILE"
    echo "--- Backup Started: $(date) ---" | tee -a "$LOG_FILE"
    rsync $RSYNC_OPTS "${SOURCE_DIRS[@]}" "$DEST_DIR" >> "$LOG_FILE" 2>&1
    RSYNC_EXIT_CODE=$?
    echo "--- Backup Finished: $(date) ---" | tee -a "$LOG_FILE"

    # --- Final Logging ---
    if [ $RSYNC_EXIT_CODE -eq 0 ]; then
      echo "✅ Rsync completed successfully." | tee -a "$LOG_FILE"
    else
      echo "❌ ERROR: Rsync failed with exit code $RSYNC_EXIT_CODE." | tee -a "$LOG_FILE"
    fi
    echo "=================================================" | tee -a "$LOG_FILE"
    exit $RSYNC_EXIT_CODE
}


# ====================================================================================
# --- Main Script Logic: Launcher or Worker? ---
# ====================================================================================

if [ "$1" = "--background" ]; then
    # ---- WORKER Part ----
    run_backup_workload
else
    # ---- LAUNCHER Part ----
    if [ "$EUID" -ne 0 ]; then
      echo "Error: This script must be run as root. Please use sudo."
      exit 1
    fi
    mkdir -p "$LOCK_DIR"

    # --- HARDENED Lock File Check ---
    if [ -e "$LOCK_FILE" ]; then
        OTHER_PID=$(cat "$LOCK_FILE")
        # IMPROVED CHECK: Look at the full command arguments ('args'), not just the command name ('comm').
        # Then, grep for the script's basename to ensure we're looking at the correct process.
        if ps -p "$OTHER_PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
            echo "❌ ERROR: Backup script appears to be running with PID: $OTHER_PID. Aborting."
            exit 1
        else
            echo "WARN: Found a stale lock file. PID $OTHER_PID is not our script or is not running. Removing it."
            rm -f "$LOCK_FILE"
        fi
    fi
    # --- End of Hardened Lock Check ---


    echo "Starting backup process in the background..."
    nohup "$0" --background > /dev/null 2>&1 &

    echo "Backup job submitted. It will run detached from this terminal."
    echo "You can monitor progress in the log files at: $LOG_DIR"
fi

exit 0