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

# Function to log messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Function to suspend the user account
suspend_user() {
  log "Suspending user account: $USER_EMAIL"
  if ! $GAM_CMD update user $USER_EMAIL suspended on; then
    log "Failed to suspend user account: $USER_EMAIL"
    exit 1
  fi
  log "User account suspended successfully: $USER_EMAIL"
}

# Function to update the user's email address
update_user_email() {
  log "Updating user's email address: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD update user $USER_EMAIL username $SUSPENDED_USER_EMAIL; then
    log "Failed to update user's email address: $USER_EMAIL"
    exit 1
  fi
  log "User's email address updated successfully: $USER_EMAIL -> $SUSPENDED_USER_EMAIL"
}

# Function to wait for a specified duration, check for aliases, and remove them if found
wait_and_check_aliases() {
  log "Waiting for aliases check and removal"
  
  # Countdown for the first sleep
  for ((i=300; i>0; i=i-10)); do
    echo "Checking for aliases in $i seconds"
    log "Checking for aliases in $i seconds"
    sleep 10
  done

  # Check if the original email is an alias for the updated email address
  log "Checking for aliases"
  alias_exists=$($GAM_CMD info user $SUSPENDED_USER_EMAIL | grep -c "Alias: $USER_EMAIL")
  if [ "$alias_exists" -gt 0 ]; then
    # Original email is an alias to the updated email address, remove it
    log "Removing alias: $USER_EMAIL"
    if ! $GAM_CMD update user $SUSPENDED_USER_EMAIL remove alias $USER_EMAIL; then
      log "Failed to remove alias: $USER_EMAIL"
      exit 1
    fi
    log "Alias removed successfully: $USER_EMAIL"
  fi

  # Countdown for the second sleep
  for ((i=300; i>0; i=i-10)); do
    echo "Waiting for next action in $i seconds"
    log "Waiting for next action in $i seconds"
    sleep 10
  done
}

# Function to create a group with the original user email
create_group() {
  log "Creating group: $USER_EMAIL"
  if ! $GAM_CMD create group "$USER_EMAIL"; then
    log "Failed to create group: $USER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Group created successfully: $USER_EMAIL"
}

# Function to add the manager as the owner of the group
add_manager_as_owner() {
  log "Adding manager as owner of the group: $MANAGER_EMAIL"
  if ! $GAM_CMD update group "$USER_EMAIL" add owner "$MANAGER_EMAIL"; then
    log "Failed to add manager as owner of the group: $MANAGER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Manager added as owner of the group: $MANAGER_EMAIL"
}

# Function to export user's email messages to a folder on their Drive
export_email_to_drive() {
  log "Exporting user's email messages to Drive: $SUSPENDED_USER_EMAIL"
  if ! $GAM_CMD user $SUSPENDED_USER_EMAIL export todrive tofolder "$ARCHIVE_LOCATION/$USER_EMAIL"; then
    log "Failed to export email messages to Drive: $SUSPENDED_USER_EMAIL"
    exit 1
  fi
  log "Email messages exported to Drive successfully: $SUSPENDED_USER_EMAIL"
}

# Function to transfer drive data to the manager
transfer_drive_data() {
  log "Transferring Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD create datatransfer $SUSPENDED_USER_EMAIL gdrive $MANAGER_EMAIL; then
    log "Failed to transfer Drive data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Drive data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
}

# Function to transfer calendar data to the manager
transfer_calendar_data() {
  log "Transferring Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
  if ! $GAM_CMD user $SUSPENDED_USER_EMAIL transfer calendars $MANAGER_EMAIL; then
    log "Failed to transfer Calendar data to manager: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
    revert_changes
    exit 1
  fi
  log "Calendar data transferred to manager successfully: $SUSPENDED_USER_EMAIL -> $MANAGER_EMAIL"
}

# Main function to execute the offboarding process
offboard_user() {
  suspend_user
  update_user_email
  wait_and_check_aliases
  create_group
  add_manager_as_owner
  export_email_to_drive
  transfer_drive_data
  transfer_calendar_data
}

# Function to revert changes if needed
revert_changes() {
  log "Reverting changes"
  # Update user email back to original
  if ! $GAM_CMD update user $SUSPENDED_USER_EMAIL username $USER_EMAIL; then
    log "Failed to revert user's email address: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  else
    log "User's email address reverted successfully: $SUSPENDED_USER_EMAIL -> $USER_EMAIL"
  fi

  # Unsuspend user
  if ! $GAM_CMD update user $USER_EMAIL suspended off; then
    log "Failed to unsuspend user account: $USER_EMAIL"
    exit 1
  fi
  log "User account unsuspended successfully: $USER_EMAIL"
}

# Call the main function to execute the offboarding process
offboard_user
