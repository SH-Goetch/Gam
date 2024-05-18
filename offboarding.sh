#!/bin/bash

# Full path to the GAM executable
GAM_CMD="$HOME/bin/gamadv-xtd3/gam"

# Path to the GAM configuration directory
export GAMCFGDIR="$HOME/GAMConfig"

# Check for required arguments
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
    delay=$((delay * 2)) # Exponential backoff
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

# 3. Create a new group for the old email with the manager as the only member
retry_group_creation
$GAM_CMD update group $USER_EMAIL add member $MANAGER_EMAIL

# 4. Transfer Drive data to the manager
$GAM_CMD create datatransfer $SUSPENDED_USER_EMAIL gdrive $MANAGER_EMAIL

# 5. Transfer Calendar data to the manager
$GAM_CMD user $SUSPENDED_USER_EMAIL transfer calendars $MANAGER_EMAIL

# 6. Archive the user's email to the manager's Drive
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

retry_email_check

# Create a Google Vault export job for the user
VAULT_EXPORT_NAME="export-$USER_EMAIL-$(date +%Y%m%d%H%M%S)"
VAULT_MATTER_ID=$($GAM_CMD create matter name "$VAULT_EXPORT_NAME" description "Email export for $USER_EMAIL" | grep 'matterId:' | awk '{print $2}')
VAULT_EXPORT_ID=$($GAM_CMD create export matter $VAULT_MATTER_ID name "$VAULT_EXPORT_NAME" query from:$SUSPENDED_USER_EMAIL to:$SUSPENDED_USER_EMAIL corpus mail dataScope allTime | grep 'exportId:' | awk '{print $2}')

# Poll the export status
while true; do
  EXPORT_STATUS=$($GAM_CMD info export $VAULT_EXPORT_ID matter $VAULT_MATTER_ID | grep 'status:' | awk '{print $2}')
  if [ "$EXPORT_STATUS" == "COMPLETED" ]; then
    echo "Export completed successfully."
    break
  elif [ "$EXPORT_STATUS" == "FAILED" ]; then
    echo "Export failed."
    revert_changes
    exit 1
  else
    echo "Export status: $EXPORT_STATUS. Checking again in 60 seconds."
    sleep 60
  fi
done

# Download the export to a local directory
EXPORT_DIRECTORY="/tmp/$VAULT_EXPORT_NAME"
mkdir -p $EXPORT_DIRECTORY
$GAM_CMD download export $VAULT_EXPORT_ID matter $VAULT_MATTER_ID exportpath $EXPORT_DIRECTORY

# Upload the export to the manager's Drive
$GAM_CMD user $MANAGER_EMAIL add drivefile localpath $EXPORT_DIRECTORY parentid $ARCHIVE_FOLDER_ID

# Clean up local export files
rm -rf $EXPORT_DIRECTORY

# 7. Delete the user's account only if the export was successful
$GAM_CMD delete user $SUSPENDED_USER_EMAIL

echo "Offboarding process for $USER_EMAIL completed successfully."
