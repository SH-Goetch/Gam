#!/bin/bash


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
NOTIFICATION_EMAIL="gstone@saybrookhome.com"

# Function to send failure email using GAM
send_failure_email() {
  SUBJECT="Email Export Failed for $USER_EMAIL"
  BODY="The email export for user $USER_EMAIL has failed. Please check the Google Vault export status for details."
  gam send email $NOTIFICATION_EMAIL subject "$SUBJECT" message "$BODY"
}

# 1. Suspend the user account
gam update user $USER_EMAIL suspended on

# 2. Rename the account
gam update user $USER_EMAIL username $SUSPENDED_USER_EMAIL

# 3. Create a new group for the old email with the manager as the only member
gam create group $USER_EMAIL
gam update group $USER_EMAIL add member $MANAGER_EMAIL

# 4. Transfer Drive data to the manager
gam create datatransfer $SUSPENDED_USER_EMAIL gdrive $MANAGER_EMAIL

# 5. Transfer Calendar data to the manager
gam user $SUSPENDED_USER_EMAIL transfer calendars $MANAGER_EMAIL

# 6. Archive the user's email to the manager's Drive
# Google Vault Export process (assuming you have a tool or API access set up for Google Vault)

# Create a folder on the manager's Drive for the email archive
ARCHIVE_FOLDER_ID=$(gam user $MANAGER_EMAIL create drivefile targetfolder $ARCHIVE_LOCATION | grep 'id:' | awk '{print $2}')

# Create a Google Vault export job for the user
VAULT_EXPORT_NAME="export-$USER_EMAIL-$(date +%Y%m%d%H%M%S)"
VAULT_MATTER_ID=$(gam create matter name "$VAULT_EXPORT_NAME" description "Email export for $USER_EMAIL" | grep 'matterId:' | awk '{print $2}')
VAULT_EXPORT_ID=$(gam create export matter $VAULT_MATTER_ID name "$VAULT_EXPORT_NAME" query from:$SUSPENDED_USER_EMAIL to:$SUSPENDED_USER_EMAIL corpus mail dataScope allTime | grep 'exportId:' | awk '{print $2}')

# Poll the export status
while true; do
  EXPORT_STATUS=$(gam info export $VAULT_EXPORT_ID matter $VAULT_MATTER_ID | grep 'status:' | awk '{print $2}')
  if [ "$EXPORT_STATUS" == "COMPLETED" ]; then
    echo "Export completed successfully."
    break
  elif [ "$EXPORT_STATUS" == "FAILED" ]; then
    echo "Export failed."
    send_failure_email
    exit 1
  else
    echo "Export status: $EXPORT_STATUS. Checking again in 60 seconds."
    sleep 60
  fi
done

# Download the export to a local directory
EXPORT_DIRECTORY="/tmp/$VAULT_EXPORT_NAME"
mkdir -p $EXPORT_DIRECTORY
gam download export $VAULT_EXPORT_ID matter $VAULT_MATTER_ID exportpath $EXPORT_DIRECTORY

# Upload the export to the manager's Drive
gam user $MANAGER_EMAIL add drivefile localpath $EXPORT_DIRECTORY parentid $ARCHIVE_FOLDER_ID

# Clean up local export files
rm -rf $EXPORT_DIRECTORY

# 7. Delete the user's account only if the export was successful
gam delete user $SUSPENDED_USER_EMAIL

echo "Offboarding process for $USER_EMAIL completed successfully."
