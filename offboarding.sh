#!/bin/bash

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

# Full path to the GAM executable
GAM_CMD="$HOME/bin/gamadv-xtd3/gam"

# Path to the GAM configuration directory
export GAMCFGDIR="$HOME/GAMConfig"

# Log file
LOG_FILE="offboarding.log"

# log messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Suspend the user account
suspend_user() {
  log "Suspending user account: $USER_EMAIL"
  if ! $GAM_CMD update user $USER_EMAIL suspended on; then
    log "Failed to suspend user account: $USER_EMAIL"
    exit 1
  fi
  log "User account suspended successfully: $USER_EMAIL"
}

# Update the user's email address
update_user_email() {
  log "Updating user's email address: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD update user $USER_EMAIL username $SUSPENDED_USER_EMAIL; then
    log "Failed to update user's email address: $USER_EMAIL"
    exit 1
  fi
  log "User's email address updated successfully: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
}

# Transfer all aliases from user to manager
transfer_aliases_to_manager() {
  log "Starting alias transfer process from $USER_EMAIL to $MANAGER_EMAIL"
  
  # Retrieve aliases from the suspended user
  aliases=$($GAM_CMD print aliases select user $USER_EMAIL | tail -n +2 | cut -d, -f1)
  
  if [ -z "$aliases" ]; then
    log "No aliases found for $USER_EMAIL"
    return
  fi

  log "Found aliases: $aliases"

  # Add each alias to the manager
  for alias in $aliases; do
    log "Transferring alias $alias to $MANAGER_EMAIL"
    if ! $GAM_CMD update alias $alias user $MANAGER_EMAIL; then
      log "Failed to transfer alias $alias to $MANAGER_EMAIL"
      exit 1
    fi

    log "Alias $alias transferred from $USER_EMAIL to $MANAGER_EMAIL successfully"
  done
}

# 11 minute wait
wait_with_count() {
  log "Starting 11-minute countdown"
  
  # Countdown for 11 minutes (660 seconds)
  for ((i=660; i>0; i=i-60)); do
    echo "Waiting for $((i / 60)) more minutes"
    log "Waiting for $((i / 60)) more minutes"
    sleep 60
  done
  
  log "11-minute wait completed"
}

short_wait_with_count() {
  log "Starting 1-minute countdown"
  
  # Countdown for 1 minute (60 seconds)
  for ((i=60; i>0; i=i-10)); do
    echo "Waiting for $((i / 10)) more seconds"
    log "Waiting for $((i / 10)) more seconds"
    sleep 10
  done
  
  log "1-minute wait completed"
}

# Remove all aliases
remove_all_aliases() {
  log "Removing all aliases for: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD user $SUSPENDED_USER_EMAIL delete aliases; then
    log "Failed to remove aliases for: $SUSPENDED_USER_EMAIL"
    exit 1
  fi
  log "All aliases removed successfully for: $SUSPENDED_USER_EMAIL"
}

# Create a group with the original user email
create_group() {
  log "Creating group: $USER_EMAIL"
  if ! $GAM_CMD create group "$USER_EMAIL"; then
    log "Failed to create group: $USER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Group created successfully: $USER_EMAIL"
}

# Add the manager as the owner of the group
add_manager_as_owner() {
  log "Adding manager as owner of the group: $MANAGER_EMAIL"
  if ! $GAM_CMD update group "$USER_EMAIL" add owner "$MANAGER_EMAIL"; then
    log "Failed to add manager as owner of the group: $MANAGER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Manager added as owner of the group: $MANAGER_EMAIL"
}

# Archive user's email messages to group
export_email_to_drive() {
  log "Archiving user's email messages to Drive: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD user $SUSPENDED_USER_EMAIL archive messages $USER_EMAIL query "smaller:25m" doit; then
    log "Failed to archive email messages: $SUSPENDED_USER_EMAIL"
    exit 1
  fi
  log "Email messages archived successfully: $SUSPENDED_USER_EMAIL"
}

# Transfer drive data to the manager
transfer_drive_data() {
  log "Transferring Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD create datatransfer $SUSPENDED_USER_EMAIL gdrive $MANAGER_EMAIL; then
    log "Failed to transfer Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    # Do not exit, continue to next step
  else
    log "Drive data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  fi
}

# Transfer calendar data to the manager
transfer_calendar_data() {
  log "Transferring Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD user $SUSPENDED_USER_EMAIL transfer calendars $MANAGER_EMAIL; then
    log "Failed to transfer Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    # Do not exit, continue to next step
  else
    log "Calendar data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  fi
}

# Delete the suspended account
delete_suspended_account() {
  log "Deleting suspended account: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD delete user $SUSPENDED_USER_EMAIL; then
    log "Failed to delete suspended account: $SUSPENDED_USER_EMAIL"
    exit 1
  fi
  log "Suspended account deleted successfully: $SUSPENDED_USER_EMAIL"
}

# offboarding process
offboard_user() {
  transfer_aliases_to_manager || { revert_changes; exit 1; }
  suspend_user || { revert_changes; exit 1; }
  update_user_email || { revert_changes; exit 1; }
  wait_with_count
  remove_all_aliases || { revert_changes; exit 1; }
  wait_with_count || { revert_changes; exit 1; }
  create_group || { revert_changes; exit 1; }
  add_manager_as_owner || { revert_changes; exit 1; }
  short_wait_with_count 
  export_email_to_drive
  transfer_drive_data
  transfer_calendar_data
  delete_suspended_account
}

# Function to revert changes if needed
revert_changes() {
  log "Reverting changes"

  # Remove manager as owner of the group
  log "Removing manager as owner of the group: $MANAGER_EMAIL"
  if ! $GAM_CMD update group "$USER_EMAIL" remove owner "$MANAGER_EMAIL"; then
    log "Failed to remove manager as owner of the group: $MANAGER_EMAIL"
  else
    log "Manager removed as owner of the group: $MANAGER_EMAIL"
  fi

  # Delete the group
  log "Deleting group: $USER_EMAIL"
  if ! $GAM_CMD delete group "$USER_EMAIL"; then
    log "Failed to delete group: $USER_EMAIL"
  else
    log "Group deleted successfully: $USER_EMAIL"
  fi

  # Short wait to ensure email address is free
  short_wait_with_count

  # Update user email back to original
  log "Updating user's email address back to original: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  if ! $GAM_CMD update user $SUSPENDED_USER_EMAIL username $USER_EMAIL; then
    log "Failed to revert user's email address: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  else
    log "User's email address reverted successfully: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  fi

  # Unsuspend user
  log "Unsuspending user account: $USER_EMAIL"
  if ! $GAM_CMD update user $USER_EMAIL suspended off; then
    log "Failed to unsuspend user account: $USER_EMAIL"
  else
    log "User account unsuspended successfully: $USER_EMAIL"
  fi
}

# Call the main function to execute the offboarding process
offboard_user
