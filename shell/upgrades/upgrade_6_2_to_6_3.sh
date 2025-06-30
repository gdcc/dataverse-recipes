#!/bin/bash
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.3

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Logging configuration
LOGFILE="$SCRIPT_DIR/dataverse_upgrade_6_2_to_6_3.log"
echo "" > "$LOGFILE"
STATE_FILE="$SCRIPT_DIR/upgrade_6_2_to_6_3.state"
PAYARA_DOWNLOAD_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2024.6/payara-6.2024.6.zip"
PAYARA_DOWNLOAD_HASH="5c67893491625d589f941309f8d83a36d1589ec8"
PAYARA_DOWNLOAD_FILE_SIZE="171966464"
REQUIRED_SPACE_KB=409600 # 400MB for download and extraction
OLD_PAYARA_VERSION_DATE="$(date +%Y.%m)"
CITATION_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/scripts/api/data/metadatablocks/citation.tsv"
BIOMEDICAL_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/scripts/api/data/metadatablocks/biomedical.tsv"
COMPUTATIONAL_WORKFLOW_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/scripts/api/data/metadatablocks/computational_workflow.tsv"
SOLR_CONFIG_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/conf/solr/solrconfig.xml"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/conf/solr/schema.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.3/conf/solr/update-fields.sh"
SOLR_VERSION="9.4.1"
SOLR_DOWNLOAD_URL="https://archive.apache.org/dist/solr/solr/9.4.1/solr-9.4.1.tgz"
TARGET_VERSION="6.3"
CURRENT_VERSION="6.2"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to check for errors and exit if found
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1. Exiting."
        exit 1
    fi
}

# Function to check if a step has been completed
is_step_completed() {
    if [ -f "$STATE_FILE" ]; then
        grep -q "^$1$" "$STATE_FILE"
    else
        return 1 # File doesn't exist, so step not completed
    fi
}

# Function to mark a step as complete
mark_step_as_complete() {
    echo "$1" >> "$STATE_FILE"
    log "Step '$1' marked as complete."
}

# Function to reset state
reset_state() {
    if [ -f "$STATE_FILE" ]; then
        rm "$STATE_FILE"
        log "Upgrade state has been reset."
    else
        log "No state file to reset."
    fi
}

# Handle command line arguments
if [[ "$1" == "--reset" ]]; then
    reset_state
    exit 0
fi

# Load environment variables from .env file
if [[ -f ".env" ]]; then
    source ".env"
    log "Loaded environment variables from .env file"
else
    log "Error: .env file not found. Please create one based on sample.env"
    exit 1
fi

# Required variables check - UPDATED to include SOLR_PATH and SOLR_USER
required_vars=(
    "DOMAIN" "PAYARA" "DATAVERSE_USER" 
    "SOLR_PATH" "SOLR_USER"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        log "Error: Required environment variable $var is not set in .env file."
        exit 1
    fi
done

DOMAIN_NAME=${DOMAIN_NAME:-"domain1"}
PAYARA_START_TIMEOUT=${PAYARA_START_TIMEOUT:-900} # Default to 15 minutes

# If current user isn't dataverse, reload this script as the dataverse user
if [ "$USER" != "$DATAVERSE_USER" ]; then
    # Prompt user to confirm they want to continue
    read -p "Current user is not $DATAVERSE_USER. This is not a big deal. Continue? (y/n): " CONTINUE
    if [[ "$CONTINUE" != [Yy] ]]; then
        log "Exiting."
        exit 1
    fi
fi

DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.3/dataverse-6.3.war"
DATAVERSE_WAR_HASH="264665217a80d4a6504b60a5978aa17f3b3205b5"
PAYARA_EXPORT_LINE="export PAYARA=\"$PAYARA\""

# Ensure the script is not run as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    log "This script runs several commands with sudo from within functions."
    exit 1
fi

# The potential issue is that files are only cleaned up in the success path of
# each function. If a function fails and returns an error, the temporary files
# may be left behind. This is a simple cleanup function that will clean up all
# potential temporary files.
cleanup_on_error() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        log "ERROR: An error occurred. Cleaning up temporary files..."
        sudo rm -rf "$TMP_DIR"
        log "Cleanup complete."
    fi
}

# This cleanup is for successful runs and should NOT remove the state file.
cleanup_on_success() {
    log "Upgrade completed successfully. Cleaning up temporary files..."
    # Add any other success-specific cleanup here if needed
    log "Success cleanup complete."
}

# Trap errors and exit
trap 'echo "An error occurred. Cleanup has been skipped for debugging purposes."' ERR
# Trap successful exit to perform final cleanup
trap cleanup_on_success EXIT

# Register cleanup function to run on script exit due to an error
trap cleanup_on_error ERR

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "grep" "sed" "sudo" "systemctl" "pgrep" "jq" "rm" "ls" "bash" "tee" "unzip" "sha1sum" "wget" "tar"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "Error: The following required commands are not installed:"
        printf ' - %s\n' "${missing_commands[@]}" | tee -a "$LOGFILE"
        echo
        log "Please install these commands before running the script."
        log "On Debian/Ubuntu systems, you can install them with:"
        log "sudo apt-get install curl grep pgrep jq rm tar"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install curl grep pgrep jq tar"
        exit 0
    fi
}

start_payara_if_needed() {
    if ! pgrep -f "payara.*$DOMAIN_NAME" > /dev/null; then
        log "Payara is not running. Starting it now..."
        sudo systemctl start payara || return 1
        log "Waiting for Payara to initialize..."
        # Wait for a few seconds for the service to start
        sleep 10
    fi
}

check_current_version() {
    local version response
    log "Checking current Dataverse version..."
    response=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications)

    # Check if "No applications are deployed to this target server" is part of the response
    if [[ "$response" == *"No applications are deployed to this target server"* ]]; then
        log "No applications are deployed to this target server. Assuming upgrade is needed."
        return 0
    fi

    # If no such message, check the Dataverse version via the API
    version=$(curl -s "http://localhost:8080/api/info/version" | grep -oP '\d+\.\d+')

    # Check if the version matches the expected current version
    if [[ $version == "$CURRENT_VERSION" ]]; then
        log "Current version is $CURRENT_VERSION as expected. Proceeding with upgrade."
        return 0
    else
        log "Current Dataverse version is not $CURRENT_VERSION. Upgrade cannot proceed."
        return 1
    fi
}

# STEP 1: Undeploy the previous version
undeploy_dataverse() {
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
        log "Undeploying current Dataverse version..."
        sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy dataverse-$CURRENT_VERSION || return 1
        log "Undeploy completed successfully."
    else
        log "Dataverse is not currently deployed. Skipping undeploy step."
    fi
}

# STEP 2: Stop Payara and remove directories
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        sudo systemctl stop payara || return 1
        log "Payara service stopped."
    else
        log "Payara is already stopped."
    fi
}

start_payara() {
    if ! pgrep -f payara > /dev/null; then
        log "Starting Payara service..."
        sudo systemctl start payara || return 1
        log "Payara service started."
    else
        log "Payara is already running."
    fi
}

clean_payara_dirs() {
    log "Removing Payara generated directories..."
    local REAL_PAYARA_DIR
    if [ -L "$PAYARA" ]; then
        REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
    else
        REAL_PAYARA_DIR="$PAYARA"
    fi

    if [ -d "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/generated" ]; then
        sudo rm -rf "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/generated" || return 1
    fi
    
    if [ -d "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/osgi-cache" ]; then
        sudo rm -rf "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/osgi-cache" || return 1
    fi
    
    if [ -d "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/lib/databases" ]; then
        sudo rm -rf "$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/lib/databases" || return 1
    fi
    
    log "Payara directories cleaned successfully."
    return 0
}

# Function to upgrade Payara to v6.2024.6
upgrade_payara() {
    log "Upgrading Payara to version 6.2024.6..."

    local REAL_PAYARA_DIR
    if [ -L "$PAYARA" ]; then
        REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
    else
        REAL_PAYARA_DIR="$PAYARA"
    fi
    local PAYARA_BACKUP_DIR="$REAL_PAYARA_DIR.$OLD_PAYARA_VERSION_DATE"

    # Step 1: Back up original Payara, if not already backed up
    if [ ! -d "$PAYARA_BACKUP_DIR" ]; then
        log "Backing up current Payara directory..."
        if [ ! -d "$REAL_PAYARA_DIR" ]; then
            log "ERROR: Cannot find current Payara directory ($REAL_PAYARA_DIR) to back up."
            return 1
        fi
        sudo mv "$REAL_PAYARA_DIR" "$PAYARA_BACKUP_DIR" || return 1
        log "Backup created at $PAYARA_BACKUP_DIR"
    else
        log "Payara directory already backed up. Skipping."
    fi

    FILE_NAME=$(basename "$PAYARA_DOWNLOAD_URL")
    local PAYARA_ZIP_FILE="$TMP_DIR/$FILE_NAME"

    # Step 2: Download new Payara, if not already downloaded
    if [ ! -f "$PAYARA_ZIP_FILE" ]; then
        log "Checking for enough space to download the new Payara version..."
        local FREE_SPACE
        FREE_SPACE=$(df -k "$TMP_DIR" | tail -n 1 | awk '{print $4}')
        if [ "$FREE_SPACE" -lt "$REQUIRED_SPACE_KB" ]; then
            log "ERROR: Not enough free space in $TMP_DIR to download and extract Payara."
            log "Required: ~$((REQUIRED_SPACE_KB / 1024))MB, Available: $((FREE_SPACE / 1024))MB."
            log "Please free up space or set the TMPDIR environment variable to a different location."
            return 1
        fi
        log "Downloading Payara 6.2024.6..."
        sudo -u "$DATAVERSE_USER" wget -P "$TMP_DIR" "$PAYARA_DOWNLOAD_URL" || return 1
        # Verify the SHA1 hash
        local CALCULATED_HASH
        CALCULATED_HASH=$(sudo -u "$DATAVERSE_USER" sha1sum "$PAYARA_ZIP_FILE" | cut -d' ' -f1)
        if [ "$CALCULATED_HASH" != "$PAYARA_DOWNLOAD_HASH" ]; then
            log "ERROR: Payara download hash verification failed."
            return 1
        fi
    else
        log "Payara zip file already downloaded. Skipping."
    fi

    # Step 3: Extract new Payara, if not already extracted
    if [ ! -d "$REAL_PAYARA_DIR" ]; then
        log "Extracting Payara..."
        sudo unzip "$PAYARA_ZIP_FILE" -d "$(dirname "$REAL_PAYARA_DIR")" || return 1
        
        local NEW_PAYARA_DIR_FROM_ZIP
        NEW_PAYARA_DIR_FROM_ZIP="$(dirname "$REAL_PAYARA_DIR")/payara6"
        if [ "$NEW_PAYARA_DIR_FROM_ZIP" != "$REAL_PAYARA_DIR" ]; then
            sudo mv "$NEW_PAYARA_DIR_FROM_ZIP" "$REAL_PAYARA_DIR" || return 1
        fi
    else
        log "New Payara directory already exists. Skipping extraction."
    fi
    
    # Step 4: Restore domain configuration from the backup
    local DOMAIN_BACKUP_PATH="$PAYARA_BACKUP_DIR/glassfish/domains/$DOMAIN_NAME"
    log "Looking for domain backup at: $DOMAIN_BACKUP_PATH"

    if [ ! -d "$DOMAIN_BACKUP_PATH" ]; then
        log "ERROR: Domain backup directory not found at $DOMAIN_BACKUP_PATH. Listing contents of backup domains directory:"
        ls -la "$PAYARA_BACKUP_DIR/glassfish/domains/"
        return 1
    fi

    log "Domain backup found. Restoring to new Payara installation..."
    sudo rm -rf "$REAL_PAYARA_DIR/glassfish/domains/domain1"
    if ! sudo mv "$DOMAIN_BACKUP_PATH" "$REAL_PAYARA_DIR/glassfish/domains/"; then
        log "ERROR: Failed to move domain from backup to new installation."
        log "Listing permissions of source and destination:"
        ls -la "$PAYARA_BACKUP_DIR/glassfish/domains/"
        ls -la "$REAL_PAYARA_DIR/glassfish/domains/"
        return 1
    fi

    log "Payara upgrade complete. New version: $PAYARA_NEW_VERSION"
    return 0
}

# Function to update domain.xml with required JVM options
update_domain_xml_options() {
    local REAL_PAYARA_DIR
    if [ -L "$PAYARA" ]; then
        REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
    else
        REAL_PAYARA_DIR="$PAYARA"
    fi
    local DOMAIN_XML="$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/config/domain.xml"

    # Check if the file exists
    if [ ! -f "$DOMAIN_XML" ]; then
        log "ERROR: domain.xml not found at $DOMAIN_XML"
        return 1
    fi
    
    # Special handling for the java.io option: remove the old version if it exists.
    # This makes the operation idempotent and safer.
    local OLD_JAVA_IO_OPT="<jvm-options>--add-opens=java.base/java.io=ALL-UNNAMED</jvm-options>"
    if sudo grep -Fq "$OLD_JAVA_IO_OPT" "$DOMAIN_XML"; then
        log "Found and removing old java.io JVM option to ensure it can be replaced..."
        sudo sed -i '/<jvm-options>--add-opens=java.base\/java.io=ALL-UNNAMED<\/jvm-options>/d' "$DOMAIN_XML"
    fi

    # Add required JVM options if not already present
    local REQUIRED_OPTIONS=(
        "--add-opens=java.management/javax.management=ALL-UNNAMED"
        "--add-opens=java.management/javax.management.openmbean=ALL-UNNAMED"
        "[17|]--add-opens=java.base/java.io=ALL-UNNAMED"
        "[21|]--add-opens=java.base/jdk.internal.misc=ALL-UNNAMED"
    )
    
    for OPTION in "${REQUIRED_OPTIONS[@]}"; do
        # Use grep -F for fixed string search, which is more robust than escaping
        if ! sudo grep -Fq "<jvm-options>$OPTION</jvm-options>" "$DOMAIN_XML"; then
            log "Adding JVM option: $OPTION"
            # Insert the new option before the </java-config> tag
            sudo sed -i "s#</java-config>#    <jvm-options>$OPTION</jvm-options>\n</java-config>#" "$DOMAIN_XML"
        else
            log "JVM option already exists: $OPTION"
        fi
    done
    
    return 0
}

# Function to update the Solr service file for Solr 9+ compatibility
update_solr_service_file() {
    log "Checking and updating Solr service file for Solr 9 compatibility..."
    local SERVICE_FILE_PATH
    if [ -f "/etc/systemd/system/solr.service" ]; then
        SERVICE_FILE_PATH="/etc/systemd/system/solr.service"
    elif [ -f "/usr/lib/systemd/system/solr.service" ]; then
        SERVICE_FILE_PATH="/usr/lib/systemd/system/solr.service"
    else
        log "WARNING: Could not find solr.service file. Skipping update. If Solr fails to start, you may need to manually update it."
        return 0
    fi
    
    log "Found Solr service file at $SERVICE_FILE_PATH"

    # Check if the file is readable
    if ! sudo test -r "$SERVICE_FILE_PATH"; then
        log "ERROR: $SERVICE_FILE_PATH is not readable by root. Aborting."
        ls -l "$SERVICE_FILE_PATH" | tee -a "$LOGFILE"
        exit 1
    fi

    # Make a backup before editing
    sudo cp "$SERVICE_FILE_PATH" "$SERVICE_FILE_PATH.bak"
    log "Backup of service file created at $SERVICE_FILE_PATH.bak"

    # Copy to temp location for editing
    local TMP_EDIT="/tmp/solr.service.edit.$$"
    sudo cp "$SERVICE_FILE_PATH" "$TMP_EDIT"
    sudo chown $USER: "$TMP_EDIT"

    # Join lines ending with '\' to handle multi-line ExecStart
    local SERVICE_CONTENT
    SERVICE_CONTENT=$(awk '{if (sub(/\\\\$/, "")) printf "%s", $0; else print $0}' "$TMP_EDIT")
    log "Service content: $SERVICE_CONTENT"

    # Extract the ExecStart line (ignore comments)
    local EXEC_LINE
    EXEC_LINE=$(echo "$SERVICE_CONTENT" | grep -E '^ExecStart[[:space:]]*=' | grep -v '^#')

    if [ -z "$EXEC_LINE" ]; then
        log "ERROR: No ExecStart line found in $SERVICE_FILE_PATH. Aborting upgrade."
        rm -f "$TMP_EDIT"
        exit 1
    fi

    log "Current ExecStart line: $EXEC_LINE"

    # Always run the sed replacement (idempotent)
    sed -i -E 's/-j[[:space:]]*["'\''"]?jetty\.host=([0-9.]+)["'\''"]?/-a "-Djetty.host=\1"/g' "$TMP_EDIT"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to update $TMP_EDIT. Check permissions:"
        ls -l "$TMP_EDIT" | tee -a "$LOGFILE"
        rm -f "$TMP_EDIT"
        exit 1
    fi
    # Re-read and log the new ExecStart line
    local NEW_SERVICE_CONTENT
    NEW_SERVICE_CONTENT=$(awk '{if (sub(/\\\\$/, "")) printf "%s", $0; else print $0}' "$TMP_EDIT")
    log "Service content: $NEW_SERVICE_CONTENT"
    local NEW_EXEC_LINE
    NEW_EXEC_LINE=$(echo "$NEW_SERVICE_CONTENT" | grep -E '^ExecStart[[:space:]]*=' | grep -v '^#')
    log "Updated ExecStart line: $NEW_EXEC_LINE"
    if [ "$NEW_EXEC_LINE" = "$EXEC_LINE" ]; then
        log "Solr service file appears to be compatible or already updated. No changes made."
    else
        sudo cp "$TMP_EDIT" "$SERVICE_FILE_PATH"
        sudo systemctl daemon-reload
        log "systemd daemon reloaded successfully."
    fi
    rm -f "$TMP_EDIT"
    return 0
}

# NEW FUNCTION: Upgrade Solr binary
upgrade_solr_binary() {
    log "Upgrading Solr binary to version $SOLR_VERSION..."
    
    # Stop Payara before altering Solr to avoid conflicts
    log "Stopping Payara service before Solr upgrade..."
    stop_payara || return 1

    # Stop Solr
    log "Stopping Solr service..."
    sudo systemctl stop solr || return 1
    
    # Backup current Solr
    local REAL_SOLR_DIR
    if [ -L "$SOLR_PATH" ]; then
        REAL_SOLR_DIR=$(readlink -f "$SOLR_PATH")
    else
        REAL_SOLR_DIR="$SOLR_PATH"
    fi
    
    if [ ! -d "${REAL_SOLR_DIR}.backup" ]; then
        log "Backing up current Solr installation..."
        sudo mv "$REAL_SOLR_DIR" "${REAL_SOLR_DIR}.backup" || return 1
    fi
    
    # Download and install Solr 9.4.1
    local SOLR_TGZ="$TMP_DIR/solr-$SOLR_VERSION.tgz"
    if [ ! -f "$SOLR_TGZ" ]; then
        log "Downloading Solr $SOLR_VERSION..."
        sudo -u "$DATAVERSE_USER" wget -O "$SOLR_TGZ" "$SOLR_DOWNLOAD_URL" || return 1
    fi
    
    log "Extracting Solr $SOLR_VERSION..."
    cd "$(dirname "$SOLR_PATH")"
    sudo tar xzf "$SOLR_TGZ" || return 1
    
    # Create symlink if original was a symlink
    if [ -L "$SOLR_PATH" ]; then
        sudo ln -sf "$(dirname "$SOLR_PATH")/solr-$SOLR_VERSION" "$SOLR_PATH" || return 1
    else
        # If not a symlink, move the extracted directory
        sudo mv "solr-$SOLR_VERSION" "$SOLR_PATH" || return 1
    fi
    
    # Restore collection1 config from backup
    log "Restoring collection1 configuration..."
    if [ -d "${REAL_SOLR_DIR}.backup/server/solr/collection1" ]; then
        sudo cp -r "${REAL_SOLR_DIR}.backup/server/solr/collection1" "$SOLR_PATH/server/solr/" || return 1
    fi
    
    # Download and update configuration files
    log "Downloading updated Solr configuration files..."
    sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/solrconfig.xml" "$SOLR_CONFIG_URL" || return 1
    sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/schema.xml" "$SOLR_SCHEMA_URL" || return 1
    
    # Copy configuration files
    log "Updating Solr configuration files..."
    sudo cp "$TMP_DIR/solrconfig.xml" "$SOLR_PATH/server/solr/collection1/conf/" || return 1
    sudo cp "$TMP_DIR/schema.xml" "$SOLR_PATH/server/solr/collection1/conf/" || return 1
    sudo rm -f "$TMP_DIR/solrconfig.xml" || return 1
    sudo rm -f "$TMP_DIR/schema.xml" || return 1

    # Set ownership
    log "Setting ownership for Solr directory..."
    # First, set ownership for the directory symlink
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH" || return 1
    # Then, set ownership for the directory itself
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH/" || return 1
    
    # Update Solr service file to be compatible with Solr 9
    update_solr_service_file || return 1

    # Start Solr
    log "Starting Solr service..."
    sudo systemctl start solr
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start Solr service. Please check the service status and logs:"
        log "sudo systemctl status solr.service"
        log "sudo journalctl -xe"
        log "Also check Solr's own logs in $SOLR_PATH/server/logs/"
        return 1
    fi
    
    # Wait for Solr to be ready
    log "Waiting for Solr to be ready..."
    local MAX_WAIT=60
    local COUNTER=0
    while [ $COUNTER -lt $MAX_WAIT ]; do
        if curl -s -f "http://localhost:8983/solr/" > /dev/null 2>&1; then
            log "Solr is ready."
            break
        fi
        sleep 2
        COUNTER=$((COUNTER + 2))
    done
    
    if [ $COUNTER -ge $MAX_WAIT ]; then
        log "WARNING: Solr may not be fully ready, but continuing..."
    fi
    
    # Start Payara again now that Solr is upgraded
    log "Starting Payara service after Solr upgrade..."
    start_payara || return 1

    # Wait for Payara to be fully started
    log "Waiting for Payara to be fully started... (timeout: $PAYARA_START_TIMEOUT seconds)"
    local PAYARA_COUNTER=0
    while [ $PAYARA_COUNTER -lt $PAYARA_START_TIMEOUT ]; do
        if curl -s -f "http://localhost:8080/api/info/version" > /dev/null; then
            log "Payara and Dataverse are fully responsive."
            break # Exit loop
        fi
        sleep 5
        PAYARA_COUNTER=$((PAYARA_COUNTER + 5))
        if [ $((PAYARA_COUNTER % 30)) -eq 0 ]; then
            log "Still waiting for Payara to start... ($PAYARA_COUNTER seconds)"
        fi
    done
    
    if [ $PAYARA_COUNTER -ge $PAYARA_START_TIMEOUT ]; then
        log "ERROR: Payara failed to start  within $PAYARA_START_TIMEOUT seconds after Solr upgrade."
        local REAL_PAYARA_DIR
        if [ -L "$PAYARA" ]; then
            REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
        else
            REAL_PAYARA_DIR="$PAYARA"
        fi
        log "Please check the Payara server log for errors: $REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/logs/server.log"
        return 1
    fi

    log "Solr binary upgrade completed successfully."
    return 0
}

# NEW FUNCTION: Update Solr schema (always run, not conditional)
update_solr_schema() {
    echo ""
    log "Updating Solr schema with Dataverse fields..."

    # Fetch schema from Dataverse API (Payara must be running)
    local SCHEMA_TMP="/tmp/schema.xml.$$"
    curl -s "http://localhost:8080/api/admin/index/solr/schema" > "$SCHEMA_TMP"
    log "First 10 lines of fetched schema from API (for merging, not for direct use as schema.xml):"
    head -10 "$SCHEMA_TMP" | tee -a "$LOGFILE"
    if ! grep -q '<field' "$SCHEMA_TMP" && ! grep -q '<copyField' "$SCHEMA_TMP"; then
        log "ERROR: The fetched schema does not contain <field> or <copyField> elements. The API endpoint may be wrong or Payara may not be running."
        cat "$SCHEMA_TMP" | tee -a "$LOGFILE"
        rm -f "$SCHEMA_TMP"
        return 1
    else
        log "Confirmed: The fetched schema from Dataverse contains <field> and <copyField> elements."
    fi
    
    # NOTE: We do not check for keywordTermURI in the API output ($SCHEMA_TMP) because
    # the API only returns field definitions for merging. The keywordTermURI field
    # will only appear in the final schema.xml after update-fields.sh merges it.

    # Stop Solr before updating schema
    log "Stopping Solr service before schema update..."
    sudo systemctl stop solr || return 1

    # Download update-fields.sh
    local SOLR_TMP_DIR=$(mktemp -d)
    chmod 755 "$SOLR_TMP_DIR"
    local UPDATE_FIELDS_SH="$SOLR_TMP_DIR/update-fields.sh"
    wget -O "$UPDATE_FIELDS_SH" "$UPDATE_FIELDS_URL" || return 1
    chmod +x "$UPDATE_FIELDS_SH" || return 1
    sudo chown "$SOLR_USER:" "$UPDATE_FIELDS_SH" || return 1
    log "update-fields.sh permissions: $(ls -l "$UPDATE_FIELDS_SH")"
    log "update-fields.sh owner: $(stat -c '%U:%G' "$UPDATE_FIELDS_SH")"

    # Log existence and permissions of schema.xml
    local SCHEMA_XML="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    if [ ! -f "$SCHEMA_XML" ]; then
        log "ERROR: schema.xml not found at $SCHEMA_XML"
        return 1
    fi
    log "schema.xml permissions: $(ls -l "$SCHEMA_XML")"
    log "schema.xml owner: $(stat -c '%U:%G' "$SCHEMA_XML")"

    # Use update-fields.sh to merge API output into existing schema.xml (never overwrite schema.xml directly)
    local UPDATE_LOG="/tmp/update-fields.log.$$"
    log "Merging new fields into schema.xml using update-fields.sh (do NOT overwrite schema.xml with API output directly)"
    log "Running: sudo -u $SOLR_USER bash $UPDATE_FIELDS_SH $SCHEMA_XML $SCHEMA_TMP > $UPDATE_LOG 2>&1"
    sudo -u "$SOLR_USER" bash "$UPDATE_FIELDS_SH" "$SCHEMA_XML" "$SCHEMA_TMP" > "$UPDATE_LOG" 2>&1
    if [ $? -ne 0 ]; then
        log "update-fields.sh failed. Output:"
        sudo cat "$UPDATE_LOG" | sudo tee -a "$LOGFILE"
        rm -f "$SCHEMA_TMP"
        rm -f "$UPDATE_LOG"
        sudo rm -rf "$SOLR_TMP_DIR"
        return 1
    fi
    rm -f "$UPDATE_LOG"
    rm -f "$SCHEMA_TMP"
    sudo rm -rf "$SOLR_TMP_DIR"

    # Verify the final schema.xml file after merge
    log "Verifying final schema.xml after merge operation..."
    if ! grep -q '<field name="keywordTermURI"' "$SCHEMA_XML"; then
        log "WARNING: keywordTermURI field is missing from schema.xml after update-fields.sh merge."
        log "This could be normal if the metadata blocks haven't been updated yet or if keywordTermURI is not used in your installation."
    else
        log "Confirmed: keywordTermURI field is present in final schema.xml."
    fi
    
    # Check that the final schema.xml is a valid XML file
    if ! xmllint --noout "$SCHEMA_XML"; then
        log "ERROR: Final schema.xml is not a valid XML file after merge. Please check the update process."
        return 1
    else
        log "Confirmed: Final schema.xml is a valid XML file."
    fi

    # Start Solr after update
    log "Starting Solr service after schema update..."
    sudo systemctl start solr
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start Solr service. Please check the service status and logs:"
        log "sudo systemctl status solr.service"
        log "sudo journalctl -xe"
        return 1
    fi

    log "Solr schema update completed successfully."
    log "NOTE: Dataverse now relies on Solr's autoCommit and autoSoftCommit settings for indexing speed. Explicit commit calls are no longer needed. See https://github.com/IQSS/dataverse/pull/10654 for details."

    return 0
}

# Function to deploy Dataverse 6.3
deploy_dataverse() {
    local DEPLOY_DIR
    DEPLOY_DIR=$(eval echo ~"$DATAVERSE_USER")/deploy
    sudo -u "$DATAVERSE_USER" mkdir -p "$DEPLOY_DIR"

    local DATAVERSE_WAR_FILENAME="dataverse-6.3.war"
    local DATAVERSE_WAR_FILE="$DEPLOY_DIR/$DATAVERSE_WAR_FILENAME"

    if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications | grep -q "dataverse-$TARGET_VERSION"; then
        log "Dataverse $TARGET_VERSION is already deployed. Skipping."
        return 0
    fi
    
    log "Downloading Dataverse 6.3 WAR file to $DEPLOY_DIR..."
    if [ ! -f "$DATAVERSE_WAR_FILE" ]; then
        sudo -u "$DATAVERSE_USER" wget -O "$DATAVERSE_WAR_FILE" "$DATAVERSE_WAR_URL" || return 1
        
        # Verify the SHA1 hash of the WAR file
        local CALCULATED_HASH
        CALCULATED_HASH=$(sudo -u "$DATAVERSE_USER" sha1sum "$DATAVERSE_WAR_FILE" | cut -d' ' -f1)
        if [ "$CALCULATED_HASH" != "$DATAVERSE_WAR_HASH" ]; then
            log "ERROR: WAR file hash verification failed. Expected: $DATAVERSE_WAR_HASH, got: $CALCULATED_HASH"
            sudo -u "$DATAVERSE_USER" rm -f "$DATAVERSE_WAR_FILE"
            return 1
        fi
    else
        log "WAR file already exists at $DATAVERSE_WAR_FILE. Skipping download."
    fi
    
    log "Deploying Dataverse 6.3..."
    # Record the current timestamp in the same format as server.log (e.g., 2025-06-17T10:03:52)
    DEPLOY_START_TIME=$(date "+%Y-%m-%dT%H:%M:%S")
    DEPLOY_OUTPUT=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" deploy "$DATAVERSE_WAR_FILE" 2>&1)
    log "Deployment output: $DEPLOY_OUTPUT"
    log "Verifying deployment status (timeout: 3 minutes)..."
    local REAL_PAYARA_DIR
    if [ -L "$PAYARA" ]; then
        REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
    else
        REAL_PAYARA_DIR="$PAYARA"
    fi
    local LOG_FILE="$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/logs/server.log"
    local MAX_WAIT=180
    local COUNTER=0

    while [ $COUNTER -lt $MAX_WAIT ]; do
        # Only consider SEVERE deployment errors after DEPLOY_START_TIME
        SEVERE_LINES=$(awk -v start="$DEPLOY_START_TIME" '
            $0 ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
                logtime = substr($0, 1, 19)
                show = (logtime >= start) ? 1 : 0
            }
            show && /SEVERE/ && /deployment/ && !/already exists/ && !/duplicate key/
        ' "$LOG_FILE")
        if [ -n "$SEVERE_LINES" ]; then
            log "ERROR: Deployment failed. SEVERE lines found:"
            echo "$SEVERE_LINES" | tee -a "$LOGFILE"
            return 1
        fi

        # Check for successful deployment by curling the API endpoint.
        if curl -s --fail "http://localhost:8080/api/info/version" &> /dev/null; then
            local version
            version=$(curl -s "http://localhost:8080/api/info/version" | jq -r '.data.version' 2>/dev/null)
            if [[ -n "$version" && "$version" == "$TARGET_VERSION"* ]]; then
                log "Deployment of dataverse-$TARGET_VERSION verified successfully. Version: $version"
                return 0
            else
                log "Dataverse is responsive, but version is '$version' (expected '$TARGET_VERSION'). Waiting..."
            fi
        fi

        sleep 5
        COUNTER=$((COUNTER + 5))
        if [ $((COUNTER % 30)) -eq 0 ]; then
             log "Still waiting for deployment confirmation... ($COUNTER seconds)"
        fi
    done

    log "ERROR: Deployment failed to verify within the timeout period."
    log "Please check the Payara server log for errors: $LOG_FILE"
    return 1
}

# Function to update internationalizat`ion (optional)
update_internationalization() {
    log "NOTE: If you are using internationalization, please update translations via Dataverse language packs."
    log "This step must be performed manually as it depends on your specific language configuration."
    # Prompt the user if they'd like to continue
    echo ""
    echo "--------------------------------"
    read -p "This is a manual step. Do you want to continue with the rest of the automated upgrade script? (y/n): " CONTINUE
    if [[ "$CONTINUE" != [Yy] ]]; then
        log "Upgrade script paused by user. Please perform the manual internationalization update and then re-run this script to continue."
        exit 1
    fi
    log "Continuing with the upgrade. Remember to perform the manual internationalization steps."
    return 0
}

# Function to restart Payara
restart_payara() {
    log "Restarting Payara service..."
    sudo systemctl stop payara || return 1
    sleep 5
    sudo systemctl start payara || return 1
    
    # Wait for Payara to start
    log "Waiting for Payara to be fully started... (timeout: $PAYARA_START_TIMEOUT seconds)"
    
    local REAL_PAYARA_DIR
    if [ -L "$PAYARA" ]; then
        REAL_PAYARA_DIR=$(readlink -f "$PAYARA")
    else
        REAL_PAYARA_DIR="$PAYARA"
    fi
    local LOG_FILE="$REAL_PAYARA_DIR/glassfish/domains/$DOMAIN_NAME/logs/server.log"
    local MAX_WAIT=$PAYARA_START_TIMEOUT
    local COUNTER=0
    
    while [ $COUNTER -lt $MAX_WAIT ]; do
        # We check the API endpoint directly. If it's responsive, we know Payara has started
        # and the Dataverse application is available.
        if curl -s -f "http://localhost:8080/api/info/version" > /dev/null; then
            log "Payara and Dataverse are fully responsive."
            return 0
        fi
        
        sleep 5
        COUNTER=$((COUNTER + 5))
        if [ $((COUNTER % 30)) -eq 0 ]; then
            log "Still waiting for Payara to start... ($COUNTER seconds)"
        fi
    done
    
    log "ERROR: Payara failed to start within $MAX_WAIT seconds."
    log "Please check the Payara server log for errors: $LOG_FILE"
    return 1
}

# Function to update metadata blocks
update_metadata_blocks() {
    log "Updating metadata blocks..."
    
    # Update citation.tsv
    log "Updating citation metadata block..."
    sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/citation.tsv" "$CITATION_TSV_URL" || return 1
    sudo -u "$DATAVERSE_USER" curl -s -f http://localhost:8080/api/admin/datasetfield/load -H "Content-type: text/tab-separated-values" -X POST --upload-file "$TMP_DIR/citation.tsv"
    check_error "Failed to update citation metadata block"
    
    # Update biomedical.tsv
    log "Updating biomedical metadata block..."
    sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/biomedical.tsv" "$BIOMEDICAL_TSV_URL" || return 1
    sudo -u "$DATAVERSE_USER" curl -s -f http://localhost:8080/api/admin/datasetfield/load -H "Content-type: text/tab-separated-values" -X POST --upload-file "$TMP_DIR/biomedical.tsv"
    check_error "Failed to update biomedical metadata block"

    echo ""
    # Ask if computational workflow metadata block is in use
    read -p "Are you using the optional computational workflow metadata block? (y/n): " USE_COMP_WORKFLOW
    if [[ "$USE_COMP_WORKFLOW" =~ ^[Yy]$ ]]; then
        log "Updating computational workflow metadata block..."
        sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/computational_workflow.tsv" "$COMPUTATIONAL_WORKFLOW_TSV_URL" || return 1
        sudo -u "$DATAVERSE_USER" curl -s -f http://localhost:8080/api/admin/datasetfield/load -H "Content-type: text/tab-separated-values" -X POST --upload-file "$TMP_DIR/computational_workflow.tsv"
        check_error "Failed to update computational workflow metadata block"
    fi
    
    log "Metadata blocks updated successfully."
    return 0
}

# Function to enable metadata source facet (optional)
enable_metadata_source_facet() {
    log "Enabling metadata source facet is optional..."
    read -p "Do you want to enable the metadata source facet for harvested content? (y/n): " ENABLE_FACET
    
    if [[ "$ENABLE_FACET" =~ ^[Yy]$ ]]; then
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options | grep -q 'dataverse.feature.index-harvested-metadata-source=true'; then
            log "Metadata source facet JVM option already exists."
        else
            log "Enabling metadata source facet..."
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "-Ddataverse.feature.index-harvested-metadata-source=true" || return 1
            log "Metadata source facet enabled. A reindex will be required."
        fi
        REINDEX_REQUIRED=true
    else
        log "Skipping metadata source facet enablement."
    fi
    
    return 0
}

# Function to enable Solr optimizations (optional)
enable_solr_optimizations() {
    log "Enabling Solr optimizations is optional but recommended for large installations..."
    log "IMPORTANT: If you want to enable the 'avoid-expensive-solr-join' search feature flag, you MUST first enable 'add-publicobject-solr-field', perform a full reindex, THEN enable 'avoid-expensive-solr-join'. Enabling both at once without a reindex will cause public objects to be missing from search results."
    read -p "Do you want to enable Solr optimizations? (y/n): " ENABLE_OPTIMIZATIONS
    
    if [[ "$ENABLE_OPTIMIZATIONS" =~ ^[Yy]$ ]]; then
        log "Enabling Solr optimizations..."
        local OPTS_TO_ADD=(
            "-Ddataverse.feature.add-publicobject-solr-field=true"
            "-Ddataverse.feature.avoid-expensive-solr-join=true"
            "-Ddataverse.feature.reduce-solr-deletes=true"
        )
        local CURRENT_OPTS
        CURRENT_OPTS=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)

        for OPT in "${OPTS_TO_ADD[@]}"; do
            if echo "$CURRENT_OPTS" | grep -qF "$OPT"; then
                log "Solr optimization JVM option already exists: $OPT"
            else
                log "Adding Solr optimization JVM option: $OPT"
                sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$OPT" || return 1
            fi
        done

        log "Solr optimizations enabled. A full reindex will be required."
        REINDEX_REQUIRED=true
    else
        log "Skipping Solr optimizations enablement."
    fi
    
    return 0
}

# Function to reindex Solr
reindex_solr() {
    # Get a count of the number of datasets in the database, use the solr api
    DATASET_COUNT=$(curl "http://localhost:8983/solr/admin/cores?wt=json" | jq .status.collection1.index.maxDoc)
    log "There are $DATASET_COUNT datasets in the database."
    echo ""
    if [ "$REINDEX_REQUIRED" = true ] || [ "$1" = "force" ]; then
        log "Reindexing Solr (this may take a while)..."
        curl -s -f http://localhost:8080/api/admin/index || return 1
        log "Solr reindexing initiated. Check server logs for progress."
    else
        log "Asking about Solr reindexing..."
        read -p "Do you want to reindex Solr? This is recommended if you upgraded Solr or enabled optional features. (y/n): " DO_REINDEX
        
        if [[ "$DO_REINDEX" =~ ^[Yy]$ ]]; then
            log "Reindexing Solr (this may take a while)..."
            curl -s -f http://localhost:8080/api/admin/index || return 1
            log "Solr reindexing initiated. Check server logs for progress."
        else
            log "Skipping Solr reindexing."
            return 0
        fi
    fi
    sleep 10
    while true; do
        DATASET_COUNT_AFTER_REINDEX=$(curl "http://localhost:8983/solr/admin/cores?wt=json" | jq .status.collection1.index.maxDoc)
        log "There are $DATASET_COUNT_AFTER_REINDEX datasets in the database after reindexing. Waiting for reindexing to finish all $DATASET_COUNT documents."
        echo ""
        # Greater than or equal to
        if [ "$DATASET_COUNT_AFTER_REINDEX" -ge "$DATASET_COUNT" ]; then
            log "Reindexing has finished."
            break
        fi
        sleep 10
    done
    return 0
}

# Function to migrate keywordTermURI (optional)
migrate_keyword_term_uri() {
    log "Data migration to the new keywordTermURI field is optional..."
    read -p "Do you want to check for and migrate keywordValue data containing URIs? (y/n): " MIGRATE_KEYWORDS
    
    if [[ "$MIGRATE_KEYWORDS" =~ ^[Yy]$ ]]; then
        log "Checking for keywordValue data containing URIs..."
        FIRST_RUN=$(sudo -u "$DB_USER" psql -d "$DB_NAME" -t -A -c "SELECT COUNT(*) FROM datasetfieldvalue dfv INNER JOIN datasetfield df ON df.id = dfv.datasetfield_id WHERE df.datasetfieldtype_id = (SELECT id FROM datasetfieldtype WHERE name = 'keywordValue') AND dfv.value ILIKE 'http%';")
        if [ "$FIRST_RUN" -gt 0 ]; then
            log "There are $FIRST_RUN rows to migrate."
        else
            log "  No rows to migrate."
            echo ""
        fi
        sudo -u "$DB_USER" psql -d "$DB_NAME" -c "UPDATE datasetfield df SET datasetfieldtype_id = (SELECT id FROM datasetfieldtype WHERE name = 'keywordTermURI') FROM datasetfieldvalue dfv WHERE dfv.datasetfield_id = df.id AND df.datasetfieldtype_id = (SELECT id FROM datasetfieldtype WHERE name = 'keywordValue') AND dfv.value ILIKE 'http%';"
        reindex_solr "force"
        # Verify the migration worked.
        SECOND_RUN=$(sudo -u "$DB_USER" psql -d "$DB_NAME" -t -A -c "SELECT COUNT(*) FROM datasetfieldvalue dfv INNER JOIN datasetfield df ON df.id = dfv.datasetfield_id WHERE df.datasetfieldtype_id = (SELECT id FROM datasetfieldtype WHERE name = 'keywordTermURI') AND dfv.value ILIKE 'http%';")
        if [ "$SECOND_RUN" -gt 0 ]; then
            log "There are $SECOND_RUN rows to migrate."
        else
            log "  No rows to migrate."
            echo ""
        fi
    else
        log "Skipping keywordTermURI data migration."
    fi
    
    return 0
}

# Function to verify upgrade
verify_upgrade() {
    log "Verifying upgrade..."
    
    # Check Dataverse version
    local VERSION
    VERSION=$(curl -s -f "http://localhost:8080/api/info/version" | jq -r '.data.version')
    
    if [[ "$VERSION" == "$CURRENT_VERSION"* || "$VERSION" == "$TARGET_VERSION"* ]]; then
        log "Dataverse version verified: $VERSION"
    else
        log "ERROR: Dataverse version verification failed. Expected: $TARGET_VERSION, got: $VERSION"
        return 1
    fi
    
    log "Upgrade verification completed successfully."
    return 0
}

# Function to perform rollback in case of failure
rollback_upgrade() {
    log "Rolling back the upgrade..."
    
    # Undeploy the new version
    log "Undeploying Dataverse $TARGET_VERSION..."
    # Check if payara is running, this is needed to undeploy.
    if sudo systemctl is-active --quiet payara; then
        log "Payara is running. Moving on the undeploy..."
    else
        log "Payara is not running. Starting it..." 
        sudo systemctl start payara || true
    fi
    sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy dataverse-$TARGET_VERSION || true
    
    # Restore Payara from backup
    if [ -d "$PAYARA.$OLD_PAYARA_VERSION_DATE" ]; then
        log "Restoring Payara from backup..."
        sudo systemctl stop payara || true
        sudo rm -rf "$PAYARA"
        sudo mv "$PAYARA.$OLD_PAYARA_VERSION_DATE" "$PAYARA"
        start_payara || true
    fi
    
    # Restore Solr from backup if it exists
    local REAL_SOLR_DIR
    if [ -L "$SOLR_PATH" ]; then
        REAL_SOLR_DIR=$(readlink -f "$SOLR_PATH")
    else
        REAL_SOLR_DIR="$SOLR_PATH"
    fi
    
    if [ -d "${REAL_SOLR_DIR}.backup" ]; then
        log "Restoring Solr from backup..."
        sudo systemctl stop solr || true
        sudo rm -rf "$SOLR_PATH"
        sudo mv "${REAL_SOLR_DIR}.backup" "$REAL_SOLR_DIR"
        sudo systemctl start solr || true
    fi
    
    log "Rollback completed. Please check the system and redeploy the previous version if necessary."
    return 0
}

# Main execution function
main() {
    log "Starting Dataverse upgrade from version $CURRENT_VERSION to $TARGET_VERSION..."
    log "To reset progress and start over, run this script with the --reset flag."
    
    start_payara_if_needed
    check_error "Failed to start Payara."

    TMP_DIR=$(mktemp -d)
    sudo chown "$DATAVERSE_USER:$DATAVERSE_USER" "$TMP_DIR"
    sudo chmod 755 "$TMP_DIR"

    # Check required commands
    if ! is_step_completed "CHECKS_COMPLETE"; then
        check_required_commands
        check_error "Required commands check failed"
        
        check_current_version
        check_error "Current version check failed"
        
        # Backup recommendation
        log "IMPORTANT: Before proceeding, ensure you have created backups of your database and Payara configuration."
        read -p "Have you created the necessary backups? (y/n): " HAS_BACKUP
        
        if [[ ! "$HAS_BACKUP" =~ ^[Yy]$ ]]; then
            log "Upgrade aborted. Please create backups before running this script again."
            exit 1
        fi
        mark_step_as_complete "CHECKS_COMPLETE"
    else
        log "Step 'CHECKS_COMPLETE' already completed. Skipping."
    fi
    
    # Initialize reindex flag
    REINDEX_REQUIRED=false
    
    # STEP 1: Undeploy the previous version
    if ! is_step_completed "UNDEPLOYED"; then
        undeploy_dataverse
        check_error "Failed to undeploy current Dataverse version"
        mark_step_as_complete "UNDEPLOYED"
    else
        log "Step 'UNDEPLOYED' already completed. Skipping."
    fi
    
    # STEP 2: Stop Payara and remove directories
    if ! is_step_completed "PAYARA_STOPPED_AND_CLEANED"; then
        stop_payara
        check_error "Failed to stop Payara service"
        
        clean_payara_dirs
        check_error "Failed to clean Payara directories"
        mark_step_as_complete "PAYARA_STOPPED_AND_CLEANED"
    else
        log "Step 'PAYARA_STOPPED_AND_CLEANED' already completed. Skipping."
    fi

    # STEP 3: Upgrade Payara
    if ! is_step_completed "PAYARA_UPGRADED"; then
        upgrade_payara
        check_error "Failed to upgrade Payara"
        mark_step_as_complete "PAYARA_UPGRADED"
    else
        log "Step 'PAYARA_UPGRADED' already completed. Skipping."
    fi

    # Start Payara before deploying
    if ! is_step_completed "PAYARA_STARTED_PRE_DEPLOY"; then
        start_payara
        check_error "Failed to start Payara service before deployment"
        mark_step_as_complete "PAYARA_STARTED_PRE_DEPLOY"
    else
        log "Step 'PAYARA_STARTED_PRE_DEPLOY' already completed. Skipping."
    fi
    
    # STEP 4: Deploy new version
    if ! is_step_completed "DATAVERSE_DEPLOYED"; then
        deploy_dataverse
        check_error "Failed to deploy new Dataverse version"
        mark_step_as_complete "DATAVERSE_DEPLOYED"
    else
        log "Step 'DATAVERSE_DEPLOYED' already completed. Skipping."
    fi
    
    # STEP 5: Update internationalization
    if ! is_step_completed "INTERNATIONALIZATION_UPDATED"; then
        update_internationalization
        mark_step_as_complete "INTERNATIONALIZATION_UPDATED"
    else
        log "Step 'INTERNATIONALIZATION_UPDATED' already completed. Skipping."
    fi
    
    # STEP 6: Restart Payara
    if ! is_step_completed "PAYARA_RESTARTED"; then
        restart_payara
        check_error "Failed to restart Payara service"
        mark_step_as_complete "PAYARA_RESTARTED"
    else
        log "Step 'PAYARA_RESTARTED' already completed. Skipping."
    fi
    
    # STEP 7: Upgrade Solr binary (without schema update)
    if ! is_step_completed "SOLR_UPGRADED"; then
        upgrade_solr_binary
        check_error "Failed to upgrade Solr binary"
        mark_step_as_complete "SOLR_UPGRADED"
    else
        log "Step 'SOLR_UPGRADED' already completed. Skipping."
    fi
    
    # STEP 8: Update metadata blocks (MUST happen before Solr schema update)
    if ! is_step_completed "METADATA_BLOCKS_UPDATED"; then
        update_metadata_blocks
        check_error "Failed to update metadata blocks"
        mark_step_as_complete "METADATA_BLOCKS_UPDATED"
    else
        log "Step 'METADATA_BLOCKS_UPDATED' already completed. Skipping."
    fi
    
    # STEP 9: Update Solr schema (MUST happen after metadata blocks)
    if ! is_step_completed "SOLR_SCHEMA_UPDATED"; then
        update_solr_schema
        check_error "Failed to update Solr schema"
        mark_step_as_complete "SOLR_SCHEMA_UPDATED"
    else
        log "Step 'SOLR_SCHEMA_UPDATED' already completed. Skipping."
    fi
    
    # STEP 10: Enable optional features
    if ! is_step_completed "OPTIONAL_FEATURES_CONFIGURED"; then
        enable_metadata_source_facet
        enable_solr_optimizations
        mark_step_as_complete "OPTIONAL_FEATURES_CONFIGURED"
    else
        log "Step 'OPTIONAL_FEATURES_CONFIGURED' already completed. Skipping."
    fi

    # STEP 11: Reindex Solr
    if ! is_step_completed "SOLR_REINDEXED"; then
        reindex_solr
        mark_step_as_complete "SOLR_REINDEXED"
    else
        log "Step 'SOLR_REINDEXED' already completed. Skipping."
    fi
    
    # Optional: Data migration for keywordTermURI
    if ! is_step_completed "KEYWORD_MIGRATION_HANDLED"; then
        migrate_keyword_term_uri
        mark_step_as_complete "KEYWORD_MIGRATION_HANDLED"
    else
        log "Step 'KEYWORD_MIGRATION_HANDLED' already completed. Skipping."
    fi
    
    # Verify upgrade
    verify_upgrade
    if [ $? -ne 0 ]; then
        log "Upgrade verification failed. Do you want to roll back? (y/n): "
        read SHOULD_ROLLBACK
        
        if [[ "$SHOULD_ROLLBACK" =~ ^[Yy]$ ]]; then
            rollback_upgrade
            exit 1
        fi
    fi
    
    log "Dataverse upgrade from version $CURRENT_VERSION to $TARGET_VERSION completed successfully!"
    log "State file has been preserved to prevent re-running completed steps."
    cleanup_on_success
    return 0
}

# Execute the main function
main