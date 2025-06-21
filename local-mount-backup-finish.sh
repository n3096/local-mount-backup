#!/bin/bash

# ====================================================================================
#
#          FILE: local-mount-backup-finish.sh
#
#         USAGE: sudo ./local-mount-backup-finish.sh
#
#   DESCRIPTION: Safely unmounts the backup HDD. It first checks if the main
#                backup script is running and will only proceed if it is not.
#
# ====================================================================================

# --- Configuration ---
# IMPORTANT: These paths MUST match the configuration in your main backup script!
DEVICE_NAME="my-device"
LOCK_DIR="/srv/scripts/backup-${DEVICE_NAME}/lock"
BACKUP_SCRIPT_NAME="backup-${DEVICE_NAME}.sh"
LOCK_FILE="${LOCK_DIR}/${BACKUP_SCRIPT_NAME}.pid"
MOUNT_POINT="/mnt/backup-usb"


# --- Pre-run Checks ---

# 1. Ensure the script is run as root, as unmounting requires privileges.
if [ "$EUID" -ne 0 ]; then
  # Redirect error messages to the standard error channel
  echo "Error: This script must be run as root. Please use sudo." >&2
  exit 1
fi


# --- Main Logic ---

echo "Attempting to safely unmount the backup drive at '$MOUNT_POINT'..."

# 1. Check if the backup script is currently running by checking for a valid lock file.
if [ -e "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    # Hardened check to see if the process with that PID is our actual backup script
    if ps -p "$PID" -o args= | grep -q "[${BACKUP_SCRIPT_NAME:0:1}]${BACKUP_SCRIPT_NAME:1}"; then
        # The backup script IS running. Abort with an error.
        echo "❌ ERROR: Cannot unmount. The backup script is currently running with PID: $PID." >&2
        exit 1
    fi
fi

# 2. If we reach this point, the backup script is not running.
#    Now, check if the drive is actually mounted before trying to unmount it.
if mountpoint -q "$MOUNT_POINT"; then
    echo "INFO: Backup is not running. Proceeding with unmount..."

    # 3. Attempt to unmount the drive.
    umount "$MOUNT_POINT"

    # 4. Check the result of the umount command.
    if [ $? -eq 0 ]; then
        echo "✅ SUCCESS: Drive at '$MOUNT_POINT' has been unmounted successfully."
        exit 0
    else
        # This can happen if another process is using the drive (e.g., an open terminal).
        echo "❌ ERROR: 'umount' command failed. The drive might be in use by another process." >&2
        echo "Tip: You can try to find the blocking process with: lsof +f -- '$MOUNT_POINT'" >&2
        exit 1
    fi
else
    echo "INFO: Drive at '$MOUNT_POINT' is already unmounted. Nothing to do."
    exit 0
fi