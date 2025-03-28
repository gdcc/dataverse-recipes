#!/bin/bash

# Dataverse Upgrade Script: 6.0 to 6.1
# This script automates the upgrade process for Dataverse from version 6.0 to 6.1
# It handles the deployment of the new version, metadata updates, and service management

# Logging configuration
LOGFILE="dataverse_upgrade.log"

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

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "systemctl" "sudo" "grep" "sed" "tee" "sha256sum" "pgrep"
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
        log "sudo apt-get install curl systemd sudo grep sed coreutils procps"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install curl systemd sudo grep sed coreutils procps-ng"
        exit 1
    fi
}

# Load environment variables from .env file
if [ -f "$(dirname "$0")/.env" ]; then
    log "Loading environment variables from .env file..."
    source "$(dirname "$0")/.env"
else
    log "Error: .env file not found in $(dirname "$0")"
    log "Please copy sample.env to .env and update the values."
    exit 1
fi

# Validate required environment variables
required_vars=(
    "DOMAIN"
    "PAYARA"
    "DATAVERSE_USER"
    "SOLR_USER"
    "SOLR_PATH"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: Required environment variable $var is not set in .env file"
        exit 1
    fi
done

# Check for required commands
check_required_commands

# Version information
CURRENT_VERSION="6.0"
TARGET_VERSION="6.1"

# URLs for required files
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.1/dataverse-6.1.war"
DATAVERSE_WAR_FILE="/home/$DATAVERSE_USER/dataverse-6.1.war"
DATAVERSE_WAR_HASH="c6e931a7498c9d560782378d62b9444699d72b9c28f82f840ec4a4ba04b72771"
GEOSPATIAL_URL="https://github.com/IQSS/dataverse/releases/download/v6.1/geospatial.tsv"
GEOSPATIAL_FILE="/tmp/geospatial.tsv"
CITATION_URL="https://github.com/IQSS/dataverse/releases/download/v6.1/citation.tsv"
CITATION_FILE="/tmp/citation.tsv"
SOLR_FIELD_UPDATER_URL="https://raw.githubusercontent.com/IQSS/dataverse/master/conf/solr/9.3.0/update-fields.sh"
SOLR_FIELD_UPDATER_FILE="/tmp/update-fields.sh"

# Application paths
DEPLOY_DIR="$PAYARA/glassfish/domains/domain1/generated"
BASHRC_FILE="/home/$DATAVERSE_USER/.bashrc"
PAYARA_EXPORT_LINE="export PAYARA=\"$PAYARA\""

# Security check: Prevent running as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    log "This script runs several commands with sudo from within functions."
    exit 1
fi

# Function to check current Dataverse version
check_current_version() {
    local version response
    response=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications)

    if [[ "$response" == *"No applications are deployed to this target server"* ]]; then
        log "No applications are deployed to this target server. Assuming upgrade is needed."
        return 0
    fi

    version=$(curl -s "http://localhost:8080/api/info/version" | grep -oP '\d+\.\d+')

    if [[ $version == "$CURRENT_VERSION" ]]; then
        return 0
    else
        log "Current Dataverse version is not $CURRENT_VERSION. Upgrade cannot proceed."
        return 1
    fi
}

# Function to undeploy the current Dataverse version
undeploy_dataverse() {
    if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
        log "Undeploying current Dataverse version..."
        sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy "dataverse-$CURRENT_VERSION" || return 1
    else
        log "Dataverse is not currently deployed. Skipping undeploy step."
    fi
}

# Function to stop Payara service
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        sudo systemctl stop payara || return 1
    else
        log "Payara is already stopped."
    fi
}

# Function to stop Solr service
stop_solr() {
    if pgrep -f solr > /dev/null; then
        log "Stopping Solr service..."
        sudo systemctl stop solr || return 1
    else
        log "Solr is already stopped."
    fi
}

# Function to start Solr service
start_solr() {
    if ! pgrep -f solr > /dev/null; then
        log "Starting Solr service..."
        sudo systemctl start solr || return 1
    else
        log "Solr is already running."
    fi
}

# Function to start Payara service
start_payara() {
    if ! pgrep -f payara > /dev/null; then
        log "Starting Payara service..."
        sudo systemctl start payara || return 1
    else
        log "Payara is already running."
    fi
}

# Function to wait for site availability
wait_for_site() {
    local url="https://${DOMAIN}/dataverse/root?q="
    local response_code

    log "Waiting for site to become available..."
    
    while true; do
        response_code=$(curl -o /dev/null -s -w "%{http_code}" "$url")

        if [[ "$response_code" -eq 200 ]]; then
            log "Site is up (HTTP 200 OK)."
            break
        else
            printf "\rWaiting... (HTTP response: %s)" "$response_code"
        fi

        sleep 1
    done
}

# Function to clean generated directory
clean_generated_dir() {
    if [[ -d "$DEPLOY_DIR" ]]; then
        log "Removing generated directory..."
        sudo rm -rf "$DEPLOY_DIR" || return 1
    else
        log "Generated directory already clean. Skipping."
    fi
}

# Function to download and verify WAR file
download_war_file() {
    if [[ -f "$DATAVERSE_WAR_FILE" ]]; then
        log "WAR file already exists at $DATAVERSE_WAR_FILE. Verifying hash..."
        ACTUAL_HASH=$(sudo -u "$DATAVERSE_USER" sha256sum "$DATAVERSE_WAR_FILE" | awk '{print $1}')
        if [ "$ACTUAL_HASH" != "$DATAVERSE_WAR_HASH" ]; then
            log "Hash mismatch! Removing old file..."
            rm -f "$DATAVERSE_WAR_FILE"
        else
            log "Hash matches! Using existing file."
            return 0
        fi
    fi
    
    log "Downloading WAR file..."
    sudo rm -f "$DATAVERSE_WAR_FILE"
    
    if ! sudo -u "$DATAVERSE_USER" bash -c "cd /home/$DATAVERSE_USER && curl -L -O \"$DATAVERSE_WAR_URL\""; then
        log "Error downloading the WAR file."
        return 1
    fi
    
    log "Setting ownership to $DATAVERSE_WAR_FILE"
    sudo chown "$DATAVERSE_USER:$DATAVERSE_USER" "$DATAVERSE_WAR_FILE"
    
    ACTUAL_HASH=$(sudo -u "$DATAVERSE_USER" sha256sum "$DATAVERSE_WAR_FILE" | awk '{print $1}')
    if [ "$ACTUAL_HASH" != "$DATAVERSE_WAR_HASH" ]; then
        log "Hash mismatch after download!"
        return 1
    else
        log "Hash matches! Download successful."
    fi
}

# Function to download and process metadata files
download_metadata_file() {
    local file_url="$1"
    local file_path="$2"
    local file_name="$3"
    
    if [[ -f "$file_path" ]]; then
        log "$file_name already exists at $file_path. Skipping download."
    else
        log "$file_name not found. Downloading..."
        
        if ! curl -L -o "$file_path" "$file_url"; then
            log "Error downloading $file_name."
            return 1
        fi
        
        log "$file_name downloaded successfully."
    fi
}

# Function to update metadata block
update_metadata_block() {
    local file_path="$1"
    local file_name="$2"
    
    if [[ -f "$file_path" ]]; then
        log "Uploading $file_name..."
        if ! sudo -u "$DATAVERSE_USER" curl http://localhost:8080/api/admin/datasetfield/load -H "Content-type: text/tab-separated-values" -X POST --upload-file "$file_path"; then
            log "Error updating with $file_name."
            return 1
        fi
        log "Update completed successfully."
        rm -f "$file_path"
    else
        log "$file_name is missing at $file_path."
        return 1
    fi
}

# Function to download and configure Solr schema updater
download_solr_schema_updater() {
    if [[ -f "$SOLR_FIELD_UPDATER_FILE" ]]; then
        log "Solr Field Updater file already exists. Skipping download."
    else
        log "Downloading Solr Field Updater..."
        if ! curl -L -o "$SOLR_FIELD_UPDATER_FILE" "$SOLR_FIELD_UPDATER_URL"; then
            log "Error downloading Solr Field Updater."
            return 1
        fi
        log "Setting permissions..."
        sudo chmod +x "$SOLR_FIELD_UPDATER_FILE"
        sudo chown "$SOLR_USER:" "$SOLR_FIELD_UPDATER_FILE"
    fi
}

# Function to update Solr schema
update_solr_schema() {
    if [[ -f "$SOLR_FIELD_UPDATER_FILE" ]]; then
        log "Updating Solr schema..."
        if ! sudo -u "$SOLR_USER" bash -c "curl \"http://localhost:8080/api/admin/index/solr/schema\" | bash $SOLR_FIELD_UPDATER_FILE $SOLR_PATH/server/solr/collection1/conf/schema.xml"; then
            log "Error updating Solr schema."
            return 1
        fi
        log "Schema update completed successfully."
        sudo rm -f "$SOLR_FIELD_UPDATER_FILE"
    else
        log "Solr Field Updater file is missing."
        return 1
    fi
}

# Function to deploy new Dataverse version
deploy_new_version() {
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications | grep -q "dataverse-$TARGET_VERSION"; then
        log "Deploying new Dataverse version..."
        sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" deploy "$DATAVERSE_WAR_FILE" || return 1
    else
        log "Dataverse version $TARGET_VERSION is already deployed. Skipping deployment."
    fi
}

# Function to export all metadata
export_all_metadata() {
    log "Exporting all metadata..."
    sudo -u "$DATAVERSE_USER" curl http://localhost:8080/api/admin/metadata/reExportAll || return 1
}

# Main function
main() {
    log "Setting Payara environment variables..."
    export PAYARA="$PAYARA"
    
    log "Checking $BASHRC_FILE for Payara export..."
    if ! sudo -u "$DATAVERSE_USER" grep -qF "$PAYARA_EXPORT_LINE" "$BASHRC_FILE"; then
        log "Adding Payara export to .bashrc..."
        sudo bash -c "echo -e '\n$PAYARA_EXPORT_LINE' >> $BASHRC_FILE"
    else
        log "Payara export already exists in .bashrc."
    fi

    log "Checking current Dataverse version..."
    if ! check_current_version; then
        log "Failed to find $CURRENT_VERSION deployed."
        exit 1
    fi

    log "Step 1: Undeploying existing version..."
    if ! undeploy_dataverse; then
        log "Error during undeploy."
        exit 1
    fi

    log "Step 2: Stopping Payara and cleaning directories..."
    if ! stop_payara || ! clean_generated_dir; then
        log "Error stopping Payara or cleaning generated directories."
        exit 1
    fi

    log "Step 3: Starting Payara..."
    if ! start_payara; then
        log "Error starting Payara."
        exit 1
    fi

    log "Step 4: Downloading and deploying WAR file..."
    if ! download_war_file; then
        log "Failed to download WAR file."
        exit 1
    fi
    
    if ! deploy_new_version; then
        log "Error deploying new version."
        exit 1
    fi

    log "Step 5: Restarting Payara..."
    if ! stop_payara || ! start_payara; then
        log "Error restarting Payara after deployment."
        exit 1
    fi

    log "Waiting for Payara to come up..."
    wait_for_site

    log "Step 6: Updating Geospatial Metadata Block..."
    if ! download_metadata_file "$GEOSPATIAL_URL" "$GEOSPATIAL_FILE" "Geospatial file"; then
        log "Failed to download geospatial file."
        exit 1
    fi
    if ! update_metadata_block "$GEOSPATIAL_FILE" "Geospatial file"; then
        log "Failed to update geospatial metadata block."
        exit 1
    fi

    log "Step 6a: Updating Citation Metadata Block..."
    if ! download_metadata_file "$CITATION_URL" "$CITATION_FILE" "Citation file"; then
        log "Failed to download citation file."
        exit 1
    fi
    if ! update_metadata_block "$CITATION_FILE" "Citation file"; then
        log "Failed to update citation metadata block."
        exit 1
    fi

    log "Step 7b: Updating Solr schema..."
    if ! stop_solr; then
        log "Error stopping Solr."
        exit 1
    fi
    if ! download_solr_schema_updater; then
        log "Failed to download Solr schema updater."
        exit 1
    fi
    if ! update_solr_schema; then
        log "Failed to update Solr schema."
        exit 1
    fi
    if ! start_solr; then
        log "Error starting Solr."
        exit 1
    fi

    log "Step 8: Exporting all metadata..."
    if ! export_all_metadata; then
        log "Error exporting all metadata."
        exit 1
    fi

    log "Checking for ImageMagick..."
    if ! command -v convert >/dev/null 2>&1; then
        log "ImageMagick is not installed."
        read -p "Would you like to install ImageMagick? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Installing ImageMagick..."
            sudo yum install -y ImageMagick || {
                log "Failed to install ImageMagick"
                exit 1
            }
        else
            log "Skipping ImageMagick installation. Note that some image functionality may be limited."
        fi
    else
        log "ImageMagick is already installed."
    fi
    
    log "Add <jvm-options>-Dconvert.path=/usr/bin/convert</jvm-options> to the domain.xml file"
    read -p "Would you like to add the jvm-options to the domain.xml file? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Adding jvm-options to the domain.xml file..."
        sudo sed -i 's/<\/jvm-options>/<jvm-options>-Dconvert.path=\/usr\/bin\/convert<\/jvm-options>/' "$PAYARA/glassfish/domains/domain1/config/domain.xml"
    fi
    log "Upgrade to Dataverse $TARGET_VERSION completed successfully."
}

# Run the main function
main "$@"
