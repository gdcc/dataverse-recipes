#!/bin/bash
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.5

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Logging configuration
LOGFILE="$SCRIPT_DIR/dataverse_upgrade_6_4_to_6_5.log"
echo "" > "$LOGFILE"
STATE_FILE="$SCRIPT_DIR/upgrade_6_4_to_6_5.state"
CITATION_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.5/scripts/api/data/metadatablocks/citation.tsv"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.5/conf/solr/schema.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.5/conf/solr/update-fields.sh"
TARGET_VERSION="6.5"
CURRENT_VERSION="6.4"

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

# Required variables check
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

DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.5/dataverse-6.5.war"
DATAVERSE_WAR_HASH="00a3176023ff2ecd6022b095e9dfa667cd012219"
PAYARA_EXPORT_LINE="export PAYARA=\"$PAYARA\""

# Ensure the script is not run as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    log "This script runs several commands with sudo from within functions."
    exit 1
fi

# Cleanup functions
cleanup_on_error() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        log "ERROR: An error occurred. Cleaning up temporary files..."
        sudo rm -rf "$TMP_DIR"
        log "Cleanup complete."
    fi
}

cleanup_on_success() {
    log "Upgrade completed successfully. Cleaning up temporary files..."
    # Add any other success-specific cleanup here if needed
    log "Success cleanup complete."
}

# Trap errors and exit
trap 'echo "An error occurred. Cleanup has been skipped for debugging purposes."' ERR
trap cleanup_on_success EXIT
trap cleanup_on_error ERR

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "grep" "sed" "sudo" "systemctl" "pgrep" "jq" "rm" "ls" "bash" "tee" "sha1sum" "wget"
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
        exit 1
    fi
}

start_payara_if_needed() {
    if ! pgrep -f "payara.*$DOMAIN_NAME" > /dev/null; then
        log "Payara is not running. Starting it now..."
        sudo systemctl start payara || return 1
        log "Waiting for Payara to initialize..."
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

# STEP 2: Stop Payara
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        sudo systemctl stop payara || return 1
        log "Payara service stopped."
    else
        log "Payara is already stopped."
    fi
}

# STEP 3: Start Payara
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

# Function to deploy Dataverse 6.5
deploy_dataverse() {
    local DEPLOY_DIR
    DEPLOY_DIR=$(eval echo ~"$DATAVERSE_USER")/deploy
    sudo -u "$DATAVERSE_USER" mkdir -p "$DEPLOY_DIR"

    local DATAVERSE_WAR_FILENAME="dataverse-6.5.war"
    local DATAVERSE_WAR_FILE="$DEPLOY_DIR/$DATAVERSE_WAR_FILENAME"

    if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications | grep -q "dataverse-$TARGET_VERSION"; then
        log "Dataverse $TARGET_VERSION is already deployed. Skipping."
        return 0
    fi
    
    log "Downloading Dataverse 6.5 WAR file to $DEPLOY_DIR..."
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
    
    log "Deploying Dataverse 6.5..."
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
        # Check for successful deployment by curling the API endpoint
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

# Function to update internationalization (optional)
update_internationalization() {
    log "NOTE: If you are using internationalization, please update translations via Dataverse language packs."
    log "This step must be performed manually as it depends on your specific language configuration."
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
    
    log "Metadata blocks updated successfully."
    return 0
}

# Function to update Solr schema
update_solr_schema() {
    log "Updating Solr schema with Dataverse fields..."

    # Stop Solr before updating schema
    log "Stopping Solr service before schema update..."
    sudo systemctl stop solr || return 1

    # Download standard v6.5 schema.xml
    log "Downloading standard v6.5 schema.xml..."
    sudo -u "$DATAVERSE_USER" wget -O "$TMP_DIR/schema.xml" "$SOLR_SCHEMA_URL" || return 1
    sudo cp "$TMP_DIR/schema.xml" "$SOLR_PATH/server/solr/collection1/conf/schema.xml" || return 1

    # Check if using custom metadata blocks
    echo ""
    read -p "Are you using any custom or experimental metadata blocks? (y/n): " USE_CUSTOM_BLOCKS
    if [[ "$USE_CUSTOM_BLOCKS" =~ ^[Yy]$ ]]; then
        log "Updating schema for custom metadata blocks..."
        
        # Start Solr temporarily to get schema from API
        sudo systemctl start solr || return 1
        sleep 10
        
        # Wait for Dataverse to be ready
        local COUNTER=0
        while [ $COUNTER -lt 60 ]; do
            if curl -s -f "http://localhost:8080/api/info/version" > /dev/null; then
                break
            fi
            sleep 2
            COUNTER=$((COUNTER + 2))
        done
        
        # Fetch schema from Dataverse API (for merging, not for direct use as schema.xml)
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
        
        # Stop Solr again
        sudo systemctl stop solr || return 1
    fi

    # Start Solr after update
    log "Starting Solr service after schema update..."
    sudo systemctl start solr || return 1

    log "Solr schema update completed successfully."
    return 0
}

# Function to reindex Solr
reindex_solr() {
    log "Asking about Solr reindexing..."
    log "NOTE: v6.5 includes improvements to role assignment reindexing that make it less memory intensive."
    read -p "Do you want to reindex Solr? This is recommended for the schema updates and performance improvements. (y/n): " DO_REINDEX
    
    if [[ "$DO_REINDEX" =~ ^[Yy]$ ]]; then
        log "Reindexing Solr (this may take a while)..."
        curl -s -f http://localhost:8080/api/admin/index || return 1
        log "Solr reindexing initiated. Check server logs for progress."
    else
        log "Skipping Solr reindexing."
    fi
    
    return 0
}

# Function to run reExportAll for metadata exports
run_reexport_all() {
    log "Running reExportAll to update dataset metadata exports..."
    log "This is necessary to ensure all metadata exports are up to date with v6.5 changes."
    
    curl -s -f http://localhost:8080/api/admin/metadata/reExportAll || return 1
    log "reExportAll initiated. This may take some time depending on the number of datasets."
    
    return 0
}

# Function to clear metrics cache (NEW for v6.5)
clear_metrics_cache() {
    log "Clearing metrics cache to fix potential bugs in /datasets and /datasets/byMonth endpoints..."
    log "v6.5 fixes bugs where metrics cache was not storing different values for dataLocation parameter."
    
    curl -X DELETE http://localhost:8080/api/admin/clearMetricsCache || return 1
    log "Metrics cache cleared successfully."
    
    return 0
}

# Function to update DataCite metadata (optional)
update_datacite_metadata() {
    log "DataCite metadata update is optional and only needed if you use DataCite as your PID provider..."
    log "NOTE: v6.5 fixes the 'useless null' bug in DataCite metadata."
    read -p "Do you use DataCite as your PID provider and want to push updated metadata? (y/n): " USE_DATACITE
    
    if [[ "$USE_DATACITE" =~ ^[Yy]$ ]]; then
        log "Updating DataCite metadata for all published datasets..."
        log "This will send corrected metadata without 'useless null' values to DataCite."
        
        read -p "Are you sure you want to update ALL published datasets at DataCite? (y/n): " CONFIRM_DATACITE
        if [[ "$CONFIRM_DATACITE" =~ ^[Yy]$ ]]; then
            log "Initiating DataCite metadata update for all datasets..."
            curl -X POST -H 'X-Dataverse-key:<YOUR_SUPERUSER_KEY>' http://localhost:8080/api/datasets/modifyRegistrationPIDMetadataAll
            check_error "Failed to update DataCite metadata"
            log "DataCite metadata update initiated. Check server logs for any failures."
            log "Any failures can be found with: grep 'Failure for id' server.log"
        else
            log "Skipping DataCite metadata update."
        fi
    else
        log "Skipping DataCite metadata update."
    fi
    
    return 0
}

# Function to verify upgrade
verify_upgrade() {
    log "Verifying upgrade..."
    
    # Check Dataverse version
    local VERSION
    VERSION=$(curl -s -f "http://localhost:8080/api/info/version" | jq -r '.data.version')
    
    if [[ "$VERSION" == "$TARGET_VERSION"* ]]; then
        log "Dataverse version verified: $VERSION"
    else
        log "ERROR: Dataverse version verification failed. Expected: $TARGET_VERSION, got: $VERSION"
        return 1
    fi
    
    log "Upgrade verification completed successfully."
    return 0
}

waiting_for_payara_to_finish_reindexing() {
    log "Firing up a more thorough reindex. This may take a while..."
    
    # Clear orphaned entries first
    curl http://localhost:8080/api/admin/index/clear-orphans || return 1

    # Clear timestamps to force complete reindex
    curl -X DELETE http://localhost:8080/api/admin/index/timestamps || return 1

    # Start the reindex (don't clear everything - that causes ranking issues)
    local previous_status=$(curl -s "http://localhost:8983/solr/admin/cores?wt=json" | jq .status.collection1.index.maxDoc)
    curl -s -f http://localhost:8080/api/admin/index/continue || return 1

    echo ""
    log "Waiting for Payara to finish reindexing..."
    while true; do
        sleep 10
        local current_status=$(curl -s "http://localhost:8983/solr/admin/cores?wt=json" | jq .status.collection1.index.maxDoc)
        log "Current status: $current_status while previous status was $previous_status. Waiting 180 seconds..."
        sleep 90

        # Check if the status has changed and is stable
        if [[ "$current_status" != "$previous_status" ]]; then
            # Wait one more cycle to make sure it's stable
            sleep 90
            local final_status=$(curl -s "http://localhost:8983/solr/admin/cores?wt=json" | jq .status.collection1.index.maxDoc)
            if [[ "$final_status" == "$current_status" ]]; then
                log "Payara has finished reindexing. Final document count: $final_status"
                break
            fi
            previous_status="$current_status"
        fi
    done
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
    
    # STEP 1: Undeploy the previous version
    if ! is_step_completed "UNDEPLOYED"; then
        undeploy_dataverse
        check_error "Failed to undeploy current Dataverse version"
        mark_step_as_complete "UNDEPLOYED"
    else
        log "Step 'UNDEPLOYED' already completed. Skipping."
    fi
    
    # STEP 2: Stop Payara and clean directories
    if ! is_step_completed "PAYARA_STOPPED_AND_CLEANED"; then
        stop_payara
        check_error "Failed to stop Payara service"
        
        clean_payara_dirs
        check_error "Failed to clean Payara directories"
        mark_step_as_complete "PAYARA_STOPPED_AND_CLEANED"
    else
        log "Step 'PAYARA_STOPPED_AND_CLEANED' already completed. Skipping."
    fi

    # STEP 3: Start Payara
    if ! is_step_completed "PAYARA_STARTED"; then
        start_payara
        check_error "Failed to start Payara service"
        mark_step_as_complete "PAYARA_STARTED"
    else
        log "Step 'PAYARA_STARTED' already completed. Skipping."
    fi
    
    # STEP 4: Deploy new version
    if ! is_step_completed "DATAVERSE_DEPLOYED"; then
        deploy_dataverse
        check_error "Failed to deploy new Dataverse version"
        mark_step_as_complete "DATAVERSE_DEPLOYED"
    else
        log "Step 'DATAVERSE_DEPLOYED' already completed. Skipping."
    fi
    
    # STEP 5: Update internationalization (optional)
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
    
    # STEP 7: Update metadata blocks
    if ! is_step_completed "METADATA_BLOCKS_UPDATED"; then
        update_metadata_blocks
        check_error "Failed to update metadata blocks"
        mark_step_as_complete "METADATA_BLOCKS_UPDATED"
    else
        log "Step 'METADATA_BLOCKS_UPDATED' already completed. Skipping."
    fi
    
    # STEP 8: Update Solr schema
    if ! is_step_completed "SOLR_SCHEMA_UPDATED"; then
        update_solr_schema
        check_error "Failed to update Solr schema"
        mark_step_as_complete "SOLR_SCHEMA_UPDATED"
    else
        log "Step 'SOLR_SCHEMA_UPDATED' already completed. Skipping."
    fi
    
    # STEP 9: Reindex Solr
    if ! is_step_completed "SOLR_REINDEXED"; then
        reindex_solr
        mark_step_as_complete "SOLR_REINDEXED"
    else
        log "Step 'SOLR_REINDEXED' already completed. Skipping."
    fi
    
    # STEP 10: Run reExportAll
    if ! is_step_completed "REEXPORT_ALL_COMPLETE"; then
        run_reexport_all
        check_error "Failed to run reExportAll"
        mark_step_as_complete "REEXPORT_ALL_COMPLETE"
    else
        log "Step 'REEXPORT_ALL_COMPLETE' already completed. Skipping."
    fi
    
    # STEP 11: Clear metrics cache (NEW for v6.5)
    if ! is_step_completed "METRICS_CACHE_CLEARED"; then
        clear_metrics_cache
        check_error "Failed to clear metrics cache"
        mark_step_as_complete "METRICS_CACHE_CLEARED"
    else
        log "Step 'METRICS_CACHE_CLEARED' already completed. Skipping."
    fi
    
    # STEP 12: Update DataCite metadata (optional)
    if ! is_step_completed "DATACITE_UPDATED"; then
        update_datacite_metadata
        mark_step_as_complete "DATACITE_UPDATED"
    else
        log "Step 'DATACITE_UPDATED' already completed. Skipping."
    fi
    
    # Verify upgrade
    verify_upgrade
    check_error "Upgrade verification failed"
    
    log "Dataverse upgrade from version $CURRENT_VERSION to $TARGET_VERSION completed successfully!"
    log ""
    log "IMPORTANT POST-UPGRADE NOTES:"
    log "1. Private URLs have been renamed to Preview URLs. Old privateUrl API endpoints are deprecated but still work."
    log "2. v6.5 includes significant performance improvements for version differences and role assignment reindexing."
    log "3. PostgreSQL and Flyway have been updated to newer versions in the containerized development environment."
    log "4. Harvesting improvements for 'oai_dc' metadata prefix with extended namespaces."
    log "5. Guestbooks now support longer custom questions (>255 characters)."
    log "6. Check the server logs for any issues with reExportAll or DataCite updates."
    log ""
    log "NEW FEATURES IN v6.5:"
    log "- Enhanced harvesting flexibility with PID from record header support"
    log "- Multiple 'otherId' values support for harvested datasets" 
    log "- Improved dataset version comparison scalability"
    log "- Better API token management with expiration information"
    log ""
    log "State file has been preserved to prevent re-running completed steps."
    cleanup_on_success
    return 0
}

# Execute the main function
main

waiting_for_payara_to_finish_reindexing
