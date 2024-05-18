#!/bin/bash

# Full path to the GAM executable
GAM_CMD="$HOME/bin/gamadv-xtd3/gam"

# Path to the GAM configuration directory
export GAMCFGDIR="$HOME/GAMConfig"

# Check for required arguments (should be exactly 2)
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 user@mycompany.com manager@mycompany.com"
  exit 1
fi

# Assign arguments to variables
USER_EMAIL=$1
MANAGER_EMAIL=$2
ARCHIVE_LOCATION="offboarded-users"
SUSPENDED_USER_EMAIL="suspended-$USER_EMAIL"

# Function to retry group creation with exponential backoff
retry_group_creation() {
  local max_retries=5
  local count=0
  local delay=10

  until $GAM_CMD create group $USER_EMAIL; do
    ((count++))
    if [ "$count" -ge "$max_retries" ]; then
      echo "Failed to create group $USER_EMAIL after $max_retries attempts."
      revert_changes
      exit 1
    fi
    echo "Group creation failed due to duplicate address. Retrying in $delay seconds..."
    sleep $delay
    delay=$((delay * 2))
  done
}

# Function to revert changes and unsuspend the user
revert_changes() {
  echo "Reverting changes for $USER_EMAIL..."
  $GAM_CMD update user $SUSPENDED_USER_EMAIL username $USER_EMAIL
  $GAM_CMD update user $USER_EMAIL suspended off
}

# Function to check if a user exists
check_user_exists() {
  $GAM_CMD info user $1 >/dev/null 2>&1
  return $?
}

# Function to remove all aliases from the user after a delay
remove_all_aliases_after_delay() {
  local delay=180
  echo "Waiting $delay seconds before removing aliases..."
  sleep $delay
  aliases=$($GAM_CMD info user $USER_EMAIL | grep 'Alias:' | awk '{print $2}')
  for alias in $aliases; do
    $GAM_CMD delete alias $alias
  done
}

# Check if the user and manager emails are valid
if ! check_user_exists $USER_EMAIL; then
  echo "Error: User $USER_EMAIL does not exist."
  exit 1
fi

if ! check_user_exists $MANAGER_EMAIL; then
  echo "Error: Manager $MANAGER_EMAIL does not exist."
  exit 1
fi

# 1. Suspend the user account
$GAM_CMD update user $USER_EMAIL suspended on

# 2. Rename the account
$GAM_CMD update user $USER_EMAIL username $SUSPENDED_USER_EMAIL

# 3. Wait 180 seconds before removing aliases
remove_all_aliases_after_delay

# 4. Remove the alias if it still exists
alias_exists=$($GAM_CMD info user $USER_EMAIL | grep "Alias: $USER_EMAIL" | wc -l)
if [ "$alias_exists" -gt 0 ]; then
  echo "Removing alias $USER_EMAIL..."
  $GAM_CMD delete alias $USER_EMAIL
fi

# 5. Create a new group for the old email with the manager as the only member
retry_group_creation
$GAM_CMD update group $USER_EMAIL add member $MANAGER_EMAIL

# 6. Transfer Drive data to the manager
$GAM_CMD create datatransfer $SUSPENDED_USER_EMAIL gdrive $MANAGER_EMAIL

# 7. Transfer Calendar data to the manager
$GAM_CMD user $SUSPENDED_USER_EMAIL transfer calendars $MANAGER_EMAIL

# 8. Archive the user's email to the manager's Drive
# Google Vault Export process (assuming you have a tool or API access set up for Google Vault)

# Create a folder on the manager's Drive for the email archive
ARCHIVE_FOLDER_ID=$($GAM_CMD user $MANAGER_EMAIL create drivefile targetfolder $ARCHIVE_LOCATION | grep 'id:' | awk '{print $2}')

# Check if the updated email address is available
retry_email_check() {
  local retries=5
  local count=0
  local delay=10

  until $GAM_CMD info user $SUSPENDED_USER_EMAIL >/dev/null 2>&1; do
    ((count++))
    if [ "$count" -ge "$retries" ]; then
      echo "Email address $SUSPENDED_USER_EMAIL is not available after $retries attempts."
      revert_changes
      exit 1
    fi
    echo "Retrying email check in $delay seconds..."
    sleep $delay
  done
}
