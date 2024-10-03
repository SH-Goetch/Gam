#!/bin/bash

# ==============================
# Offboarding Script for Users
# ==============================

# **Description:**
# This script automates the offboarding process for a user in a Google Workspace environment.
# It performs the following actions:
# 1. Suspend the user's account.
# 2. Change the user's email address to a suspended state.
# 3. Create a new group with the user's old email address and assign the manager as the owner.
# 4. Wait for the email address changes to take effect.
# 5. Transfer the user's aliases to the manager.
# 6. Archive the user's emails to the new group with error handling and logging.
# 7. Transfer the user's Drive and Calendar data to the manager.
# 8. Delete the suspended account.

# **Usage:**
# ./offboard_user.sh user@mycompany.com manager@mycompany.com

# ==============================
# Configuration
# ==============================

# Check for required arguments (should be exactly 2)
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 user@mycompany.com manager@mycompany.com"
  exit 1
fi

# Assign arguments to variables
USER_EMAIL="$1"
MANAGER_EMAIL="$2"
ARCHIVE_LOCATION="offboarded-users"
SUSPENDED_USER_EMAIL="suspended-$USER_EMAIL"

# Full path to the GAMADV-XTD3 executable
GAM_CMD="$HOME/bin/gamadv-xtd3/gam"

# Path to the GAM configuration directory
export GAMCFGDIR="$HOME/GAMConfig"

# Log files
LOG_FILE="offboarding.log"
ARCHIVE_LOG="archive_success.log"
FAILED_ARCHIVE_LOG="archive_failed.log"

# Maximum number of archive retries per message
MAX_RETRIES=3

# Wait durations (in seconds)
WAIT_DURATION=660  # 11 minutes
SHORT_WAIT_DURATION=60  # 1 minute

# ==============================
# Helper Functions
# ==============================

# Log general messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $1" | tee -a "$LOG_FILE"
}

# Log archive successes
log_archive_success() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') SUCCESS: $1" | tee -a "$ARCHIVE_LOG"
}

# Log archive failures
log_archive_failure() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') FAILURE: $1" | tee -a "$FAILED_ARCHIVE_LOG"
}

# Wait with logging
wait_with_count() {
  local duration=$1
  local label=$2
  log "Starting countdown: $label for $((duration / 60)) minutes."
  
  for ((i=duration; i>0; i-=60)); do
    minutes=$((i / 60))
    if [ "$minutes" -gt 0 ]; then
      echo "Waiting for $minutes more minutes..."
      log "Waiting for $minutes more minutes."
      sleep 60
    fi
  done
  
  log "$label wait completed."
}

# Short wait with logging
short_wait_with_count() {
  log "Starting short countdown: 1 minute."
  
  for ((i=SHORT_WAIT_DURATION; i>0; i-=10)); do
    echo "Waiting for $((i / 10)) more seconds..."
    log "Waiting for $((i / 10)) more seconds."
    sleep 10
  done
  
  log "Short wait completed."
}

# Revert changes in case of failure
revert_changes() {
  log "Reverting changes..."

  # Remove manager as owner of the group
  log "Removing manager as owner of the group: $MANAGER_EMAIL"
  if ! $GAM_CMD update group "$USER_EMAIL" remove owner "$MANAGER_EMAIL"; then
    log "ERROR: Failed to remove manager as owner of the group: $MANAGER_EMAIL"
  else
    log "Manager removed as owner of the group: $MANAGER_EMAIL"
  fi

  # Delete the group
  log "Deleting group: $USER_EMAIL"
  if ! $GAM_CMD delete group "$USER_EMAIL"; then
    log "ERROR: Failed to delete group: $USER_EMAIL"
  else
    log "Group deleted successfully: $USER_EMAIL"
  fi

  # Short wait to ensure email address is free
  short_wait_with_count

  # Update user email back to original
  log "Updating user's email address back to original: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  if ! $GAM_CMD update user "$SUSPENDED_USER_EMAIL" username "$USER_EMAIL"; then
    log "ERROR: Failed to revert user's email address: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  else
    log "User's email address reverted successfully: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  fi

  # Unsuspend user
  log "Unsuspending user account: $USER_EMAIL"
  if ! $GAM_CMD update user "$USER_EMAIL" suspended off; then
    log "ERROR: Failed to unsuspend user account: $USER_EMAIL"
  else
    log "User account unsuspended successfully: $USER_EMAIL"
  fi
}

# ==============================
# Main Functionalities
# ==============================

# Suspend the user account
suspend_user() {
  log "Suspending user account: $USER_EMAIL"
  if ! $GAM_CMD update user "$USER_EMAIL" suspended on; then
    log "ERROR: Failed to suspend user account: $USER_EMAIL"
    exit 1
  fi
  log "User account suspended successfully: $USER_EMAIL"
}

# Update the user's email address
update_user_email() {
  log "Updating user's email address: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD update user "$USER_EMAIL" username "$SUSPENDED_USER_EMAIL"; then
    log "ERROR: Failed to update user's email address: $USER_EMAIL"
    exit 1
  fi
  log "User's email address updated successfully: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
}

# Transfer all aliases from user to manager
transfer_aliases_to_manager() {
  log "Starting alias transfer process from $USER_EMAIL to $MANAGER_EMAIL"
  
  # Retrieve aliases from the suspended user
  aliases=$($GAM_CMD print aliases user "$USER_EMAIL" | tail -n +2 | cut -d, -f1)
  
  if [ -z "$aliases" ]; then
    log "No aliases found for $USER_EMAIL"
    return
  fi

  log "Found aliases: $aliases"

  # Add each alias to the manager
  for alias in $aliases; do
    log "Transferring alias $alias to $MANAGER_EMAIL"
    if ! $GAM_CMD update alias "$alias" user "$MANAGER_EMAIL"; then
      log "ERROR: Failed to transfer alias $alias to $MANAGER_EMAIL"
      exit 1
    fi

    log "Alias $alias transferred from $USER_EMAIL to $MANAGER_EMAIL successfully"
  done
}

# Create a group with the original user email
create_group() {
  log "Creating group: $USER_EMAIL"
  if ! $GAM_CMD create group "$USER_EMAIL"; then
    log "ERROR: Failed to create group: $USER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Group created successfully: $USER_EMAIL"
}

# Add the manager as the owner of the group
add_manager_as_owner() {
  log "Adding manager as owner of the group: $MANAGER_EMAIL"
  if ! $GAM_CMD update group "$USER_EMAIL" add owner "$MANAGER_EMAIL"; then
    log "ERROR: Failed to add manager as owner of the group: $MANAGER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Manager added as owner of the group: $MANAGER_EMAIL"
}

# Archive a single email message with retries
archive_single_message() {
  local MESSAGE_ID="$1"
  local RETRIES=0
  local SUCCESS=0
  
  log "Archiving message ID: $MESSAGE_ID"

  while [ $RETRIES -lt $MAX_RETRIES ]; do
    if $GAM_CMD user "$SUSPENDED_USER_EMAIL" archive messages "$MESSAGE_ID" query "smaller:25m" doit; then
      log_archive_success "$MESSAGE_ID"
      SUCCESS=1
      break
    else
      RETRIES=$((RETRIES + 1))
      log "WARNING: Attempt $RETRIES failed for message ID: $MESSAGE_ID"
      sleep 5  # Wait before retrying
    fi
  done

  if [ $SUCCESS -ne 1 ]; then
    log_archive_failure "$MESSAGE_ID"
  fi
}

# Archive user's email messages to the new group with error handling
export_email_to_drive() {
  log "Archiving user's email messages to group: $USER_EMAIL"

  # Retrieve all message IDs to be archived
  # Using GAMADV-XTD3 syntax as per documentation
  message_ids=$($GAM_CMD user "$SUSPENDED_USER_EMAIL" print messages query "smaller:25m" fields id | tail -n +2 | awk '{print $1}')

  if [ -z "$message_ids" ]; then
    log "No messages found to archive for: $SUSPENDED_USER_EMAIL"
    return
  fi

  log "Found $(echo "$message_ids" | wc -l) messages to archive."

  # Iterate through each message ID and attempt to archive individually
  for msg_id in $message_ids; do
    # Check if the message has already been archived
    if grep -q "^SUCCESS: $msg_id$" "$ARCHIVE_LOG"; then
      log "Message ID $msg_id already archived. Skipping."
      continue
    fi
    archive_single_message "$msg_id"
  done

  log "Email archiving process completed for: $SUSPENDED_USER_EMAIL"
}

# Transfer Drive data to the manager
transfer_drive_data() {
  log "Transferring Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD transfer drive "$SUSPENDED_USER_EMAIL" "$MANAGER_EMAIL"; then
    log "ERROR: Failed to transfer Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    # Do not exit, continue to next step
  else
    log "Drive data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  fi
}

# Transfer Calendar data to the manager
transfer_calendar_data() {
  log "Transferring Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD transfer calendars "$SUSPENDED_USER_EMAIL" "$MANAGER_EMAIL"; then
    log "ERROR: Failed to transfer Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    # Do not exit, continue to next step
  else
    log "Calendar data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  fi
}

# Remove all aliases from the suspended user
remove_all_aliases() {
  log "Removing all aliases for: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD user "$SUSPENDED_USER_EMAIL" delete aliases; then
    log "ERROR: Failed to remove aliases for: $SUSPENDED_USER_EMAIL"
    revert_changes
    exit 1
  fi
  log "All aliases removed successfully for: $SUSPENDED_USER_EMAIL"
}

# Delete the suspended account
delete_suspended_account() {
  log "Deleting suspended account: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD delete user "$SUSPENDED_USER_EMAIL"; then
    log "ERROR: Failed to delete suspended account: $SUSPENDED_USER_EMAIL"
    exit 1
  fi
  log "Suspended account deleted successfully: $SUSPENDED_USER_EMAIL"
}

# ==============================
# Offboarding Process
# ==============================

offboard_user() {
  transfer_aliases_to_manager || { revert_changes; exit 1; }
  suspend_user || { revert_changes; exit 1; }
  update_user_email || { revert_changes; exit 1; }
  wait_with_count "$WAIT_DURATION" "Email address update"
  remove_all_aliases || { revert_changes; exit 1; }
  wait_with_count "$WAIT_DURATION" "Alias removal"
  create_group || { revert_changes; exit 1; }
  add_manager_as_owner || { revert_changes; exit 1; }
  short_wait_with_count
  export_email_to_drive
  transfer_drive_data
  transfer_calendar_data
  delete_suspended_account
}

# ==============================
# Execute Offboarding
# ==============================

# Start the offboarding process
offboard_user

log "Offboarding process completed for user: $USER_EMAIL"

# Optionally, send a summary email to the manager or admin about the offboarding status
# This section can be implemented based on your organization's requirements.

exit 0
