#!/bin/bash
# set -x
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.7
#
# This script is designed to be enterprise-grade, production-ready, and suitable for
# distribution across institutions. It incorporates robust error handling, state
# management, and verification at each step to ensure a reliable and repeatable
# upgrade process.

# Version information
TARGET_VERSION="6.7"
CURRENT_VERSION="6.6"
PAYARA_VERSION="6.2025.3"
SOLR_VERSION="9.8.0" # No change from v6.6
REQUIRED_JAVA_VERSION="11" # No change from v6.6

# URLs for downloading files
PAYARA_DOWNLOAD_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2025.3/payara-6.2025.3.zip"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.7/dataverse-6.7.war"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.7/conf/solr/schema.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.7/conf/solr/update-fields.sh"

# SHA256 checksums for verification
PAYARA_SHA256="88f5c1e5b40ea4bc60ae3e34e6858c1b33145dc06c4b05c3d318ed67c131e210"
DATAVERSE_WAR_SHA256="2c71e7a238daf09bd9854b1c235192eb1e9eacb3cb912150f872e63fd4e5166f"
SOLR_SCHEMA_SHA256="6acc401c367293112179ad80bac8230435abb542e9cfb7dc637fbabbb674d436"
UPDATE_FIELDS_SHA256="de66d7baecc60fbe7846da6db104701317949b3a0f1ced5df3d3f6e34b634c7c"

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
DOWNLOAD_CACHE_DIR="$SCRIPT_DIR/downloads"

# Logging configuration
LOGFILE="$SCRIPT_DIR/dataverse_upgrade_6_6_to_6_7.log"
echo "" > "$LOGFILE"
STATE_FILE="$SCRIPT_DIR/upgrade_6_6_to_6_7.state"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to check for errors and exit if found
check_error() {
    if [ $? -ne 0 ]; then
        log "❌ ERROR: $1. Exiting."
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

# Function to mark a step as running (to detect interruptions)
mark_step_as_running() {
    local step_name="$1"
    if [ -f "$STATE_FILE" ]; then
        grep -v "^${step_name}_running$\|^${step_name}_failed$" "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "${step_name}_running" >> "$STATE_FILE"
    log "Step '$step_name' marked as running..."
}

# Function to mark a step as complete
mark_step_as_complete() {
    local step_name="$1"
    if [ -f "$STATE_FILE" ]; then
        grep -v "^${step_name}_running$\|^${step_name}_failed$" "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "$step_name" >> "$STATE_FILE"
    log "✅ Step '$step_name' marked as complete."
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
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
    log "Loaded environment variables from .env file"
else
    log "❌ Error: .env file not found. Please create one based on sample.env"
    exit 1
fi

# Required variables check
required_vars=(
    "DOMAIN" "PAYARA" "DATAVERSE_USER" "WAR_FILE_LOCATION"
    "SOLR_PATH" "SOLR_USER"
)
# Optional variables for database operations
optional_vars=(
    "DB_USER" "DB_NAME"
)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        log "❌ Error: Required environment variable $var is not set in .env file."
        exit 1
    fi
done

# Ensure the script is not run as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    exit 1
fi

# Cleanup functions
cleanup_on_error() {
    log "❌ ERROR: An error occurred during the upgrade."
    # Add any specific error cleanup logic here
}

cleanup_on_success() {
    log "✅ Upgrade completed successfully. Cleaning up temporary files..."
    # Add any success-specific cleanup here if needed
}

trap 'cleanup_on_error' ERR
trap 'cleanup_on_success' EXIT

# Function to download a file with caching and checksum verification
download_with_cache() {
    local url="$1"
    local file_name="$2"
    local file_description="$3"
    local expected_sha256="$4"
    local dest_path="$DOWNLOAD_CACHE_DIR/$file_name"

    log "Handling download for $file_description..."
    mkdir -p "$DOWNLOAD_CACHE_DIR"

    if [ -f "$dest_path" ]; then
        log "File found in cache: $dest_path"
        if [ -n "$expected_sha256" ]; then
            log "Verifying checksum of cached file..."
            local actual_sha256=$(sha256sum "$dest_path" | awk '{print $1}')
            if [ "$actual_sha256" == "$expected_sha256" ]; then
                log "✓ Checksum for cached '$file_description' is valid. Skipping download."
                return 0
            else
                log "✗ Checksum mismatch for cached file. Deleting and re-downloading."
                rm -f "$dest_path"
            fi
        else
            return 0
        fi
    fi

    log "Downloading $file_description from $url..."
    wget --timeout=60 --tries=3 -O "$dest_path" "$url"
    check_error "Failed to download $file_description"

    if [ -n "$expected_sha256" ]; then
        local actual_sha256=$(sha256sum "$dest_path" | awk '{print $1}')
        if [ "$actual_sha256" != "$expected_sha256" ]; then
            log "❌ ERROR: Checksum verification failed for downloaded file."
            rm -f "$dest_path"
            return 1
        fi
    fi
    log "✓ Download of $file_description complete and verified."
    return 0
}

# Function to check current Dataverse version
check_current_version() {
    log "Checking current Dataverse version..."
    local version
    version=$(curl -s "http://localhost:8080/api/info/version" | jq -r '.data.version')
    if [[ "$version" == "$CURRENT_VERSION"* ]]; then
        log "✓ Current version is $CURRENT_VERSION as expected."
        return 0
    elif [[ "$version" == "$TARGET_VERSION"* ]]; then
        log "✓ System is already at target version $TARGET_VERSION. No upgrade needed."
        exit 0
    else
        log "❌ ERROR: Current Dataverse version is '$version', but this script requires '$CURRENT_VERSION'."
        return 1
    fi
}

# Function to undeploy the current Dataverse version
undeploy_dataverse() {
    log "Undeploying Dataverse $CURRENT_VERSION..."
    sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy "dataverse-$CURRENT_VERSION"
    check_error "Failed to undeploy Dataverse"
}

# Function to stop a service
stop_service() {
    log "Stopping $1 service..."
    sudo systemctl stop "$1"
    check_error "Failed to stop $1"
}

# Function to start a service
start_service() {
    log "Starting $1 service..."
    sudo systemctl start "$1"
    check_error "Failed to start $1"
}

# Function to upgrade Payara
upgrade_payara() {
    log "Upgrading Payara to version $PAYARA_VERSION..."
    local payara_zip="payara-$PAYARA_VERSION.zip"
    local payara_dir="payara6" # The directory name inside the zip

    download_with_cache "$PAYARA_DOWNLOAD_URL" "$payara_zip" "Payara $PAYARA_VERSION" "$PAYARA_SHA256"
    check_error "Payara download failed"

    local payara_parent_dir=$(dirname "$PAYARA")
    local payara_backup_dir="$PAYARA.$CURRENT_VERSION.bak"

    log "Backing up current Payara directory to $payara_backup_dir..."
    sudo mv "$PAYARA" "$payara_backup_dir"
    check_error "Failed to backup Payara directory"

    log "Extracting new Payara version..."
    sudo unzip -q "$DOWNLOAD_CACHE_DIR/$payara_zip" -d "$payara_parent_dir"
    check_error "Failed to unzip Payara"

    # The unzipped directory is named payara6, rename it to match the original PAYARA path if they differ
    if [ "$payara_parent_dir/$payara_dir" != "$PAYARA" ]; then
        sudo mv "$payara_parent_dir/$payara_dir" "$PAYARA"
        check_error "Failed to rename unzipped Payara directory"
    fi

    log "Restoring domain configuration..."
    sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_new"
    check_error "Failed to move new domain directory"
    sudo mv "$payara_backup_dir/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
    check_error "Failed to restore old domain directory"
}

# Function to deploy the new Dataverse WAR file
deploy_dataverse() {
    log "Deploying Dataverse $TARGET_VERSION..."
    local war_file="dataverse-$TARGET_VERSION.war"
    download_with_cache "$DATAVERSE_WAR_URL" "$war_file" "Dataverse $TARGET_VERSION WAR" "$DATAVERSE_WAR_SHA256"
    check_error "Dataverse WAR download failed"

    sudo -u "$DATAVERSE_USER" cp "$DOWNLOAD_CACHE_DIR/$war_file" "$WAR_FILE_LOCATION/"
    check_error "Failed to copy WAR file to deployment location"

    sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" deploy "$WAR_FILE_LOCATION/$war_file"
    check_error "Failed to deploy Dataverse WAR"
}

# Function to migrate API filters
migrate_api_filters() {
    log "Migrating API filter settings from database to JVM options..."

    # Check if new settings already exist
    local jvm_options
    jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    if echo "$jvm_options" | grep -q "dataverse.api.blocked.policy"; then
        log "API filter JVM options already seem to be configured. Skipping migration."
        return 0
    fi

    log "Fetching old API filter settings..."
    local allow_cors
    allow_cors=$(curl -s http://localhost:8080/api/admin/settings/:AllowCors)
    local blocked_endpoints_raw
    blocked_endpoints_raw=$(curl -s http://localhost:8080/api/admin/settings/:BlockedApiEndpoints)
    # Extract the actual blocked endpoints value from JSON response
    local blocked_endpoints
    if command -v jq >/dev/null 2>&1; then
        blocked_endpoints=$(echo "$blocked_endpoints_raw" | jq -r '.data.message // .data // . // empty' 2>/dev/null || echo "$blocked_endpoints_raw")
    else
        # Fallback: try to extract value using grep/sed if jq is not available
        blocked_endpoints=$(echo "$blocked_endpoints_raw" | grep -o '"message":"[^"]*"' | sed 's/"message":"//;s/"$//' 2>/dev/null || echo "$blocked_endpoints_raw")
    fi
    local blocked_policy_raw
    blocked_policy_raw=$(curl -s http://localhost:8080/api/admin/settings/:BlockedApiPolicy)
    # Extract the actual blocked policy value from JSON response
    local blocked_policy
    if command -v jq >/dev/null 2>&1; then
        blocked_policy=$(echo "$blocked_policy_raw" | jq -r '.data.message // .data // . // empty' 2>/dev/null || echo "$blocked_policy_raw")
    else
        # Fallback: try to extract value using grep/sed if jq is not available
        blocked_policy=$(echo "$blocked_policy_raw" | grep -o '"message":"[^"]*"' | sed 's/"message":"//;s/"$//' 2>/dev/null || echo "$blocked_policy_raw")
    fi
    local blocked_key
    blocked_key=$(curl -s http://localhost:8080/api/admin/settings/:BlockedApiKey)

    if [[ "$allow_cors" != "true" ]]; then
        log "Setting CORS origin..."
        if ! echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "-Ddataverse.cors.origin=*"
            check_error "Failed to set CORS origin"
        else
            log "CORS origin JVM option already exists. Skipping."
        fi
    fi

    if [ -n "$blocked_endpoints" ] && [ "$blocked_endpoints" != "{}" ]; then
        log "Setting blocked endpoints..."
        log "DEBUG: blocked_endpoints_raw value: '$blocked_endpoints_raw'"
        log "DEBUG: blocked_endpoints extracted value: '$blocked_endpoints'"
        if ! echo "$jvm_options" | grep -q "dataverse.api.blocked.endpoints"; then
            local jvm_option="-Ddataverse.api.blocked.endpoints=$blocked_endpoints"
            log "DEBUG: jvm_option value: '$jvm_option'"
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "$jvm_option"
            check_error "Failed to set blocked endpoints"
        else
            log "Blocked endpoints JVM option already exists. Skipping."
        fi
    fi

    if [ -n "$blocked_policy" ] && [ "$blocked_policy" != "{}" ] && [ "$blocked_policy" != "drop" ]; then
        log "Setting blocked policy..."
        if ! echo "$jvm_options" | grep -q "dataverse.api.blocked.policy"; then
            local jvm_option="-Ddataverse.api.blocked.policy=$blocked_policy"
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "$jvm_option"
            check_error "Failed to set blocked policy"
        else
            log "Blocked policy JVM option already exists. Skipping."
        fi
    fi

    if [ "$blocked_policy" == "unblock-key" ] && [ -n "$blocked_key" ] && [ "$blocked_key" != "{}" ]; then
        log "Creating password alias for API key..."
        echo "AS_ADMIN_ALIASPASSWORD=$blocked_key" > /tmp/dataverse.api.blocked.key.txt
        sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-password-alias --passwordfile /tmp/dataverse.api.blocked.key.txt api_blocked_key_alias
        check_error "Failed to create password alias"
        rm /tmp/dataverse.api.blocked.key.txt

        log "Setting API blocked key..."
        if ! echo "$jvm_options" | grep -q "dataverse.api.blocked.key"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options '-Ddataverse.api.blocked.key=${ALIAS=api_blocked_key_alias}'
            check_error "Failed to set API blocked key"
        else
            log "API blocked key JVM option already exists. Skipping."
        fi
    fi

    log "Cleaning up old database settings..."
    curl -X DELETE http://localhost:8080/api/admin/settings/:AllowCors
    curl -X DELETE http://localhost:8080/api/admin/settings/:BlockedApiEndpoints
    curl -X DELETE http://localhost:8080/api/admin/settings/:BlockedApiPolicy
    curl -X DELETE http://localhost:8080/api/admin/settings/:BlockedApiKey

    log "API filter migration complete. Restarting Payara for changes to take effect."
    stop_service "payara"
    start_service "payara"
    log "Waiting for Payara to fully start after API filter migration..."
    sleep 30
}

# Function to update content type for VTT files
redetect_vtt_files() {
    log "Checking for existing .vtt files with incorrect content type..."
    if [[ -z "$DB_USER" || -z "$DB_NAME" ]]; then
        log "WARNING: DB_USER or DB_NAME not set in .env file. Skipping VTT file update."
        return 0
    fi

    local vtt_files_count
    vtt_files_count=$(sudo -u "$DB_USER" psql -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM datafile f JOIN filemetadata m ON f.id = m.datafile_id WHERE f.contenttype = 'application/octet-stream' AND m.label LIKE '%.vtt';")
    vtt_files_count=$(echo "$vtt_files_count" | xargs) # trim whitespace

    if [ "$vtt_files_count" -gt 0 ]; then
        log "Found $vtt_files_count .vtt files to update."
        read -p "Do you want to update their content type in the database? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "Updating content type for .vtt files..."
            sudo -u "$DB_USER" psql -d "$DB_NAME" -c "UPDATE datafile SET contenttype = 'text/vtt' WHERE id IN (SELECT datafile_id FROM filemetadata m JOIN datafile f ON f.id = m.datafile_id WHERE f.contenttype = 'application/octet-stream' AND m.label LIKE '%.vtt');"
            check_error "Failed to update VTT files content type"
            log "Content type updated. These files will be reindexed in the next step."
        else
            log "Skipping VTT file content type update."
        fi
    else
        log "No .vtt files with incorrect content type found."
    fi
}

# Function to update Solr schema
update_solr_schema() {
    log "Updating Solr schema..."
    stop_service "solr"

    local schema_file="schema.xml"
    download_with_cache "$SOLR_SCHEMA_URL" "$schema_file" "Solr schema" "$SOLR_SCHEMA_SHA256"
    check_error "Solr schema download failed"

    sudo cp "$DOWNLOAD_CACHE_DIR/$schema_file" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    check_error "Failed to copy Solr schema"

    read -p "Do you have custom metadata blocks? (y/N): " custom_blocks
    if [[ "$custom_blocks" =~ ^[Yy]$ ]]; then
        log "Updating fields for custom metadata blocks..."
        local update_script="update-fields.sh"
        download_with_cache "$UPDATE_FIELDS_URL" "$update_script" "Solr update script" "$UPDATE_FIELDS_SHA256"
        check_error "Solr update script download failed"

        sudo chmod +x "$DOWNLOAD_CACHE_DIR/$update_script"
        # Start payara temporarily for the update script to get schema from API
        start_service "payara"
        sleep 30 # Give payara time to start
        sudo -u "$SOLR_USER" bash -c "curl \"http://localhost:8080/api/admin/index/solr/schema\" | $DOWNLOAD_CACHE_DIR/$update_script $SOLR_PATH/server/solr/collection1/conf/schema.xml"
        check_error "Failed to update Solr fields"
        stop_service "payara"
    fi

    start_service "solr"
}

# Function to reindex Solr
reindex_data() {
    log "Reindexing Solr..."
    curl http://localhost:8080/api/admin/index
    check_error "Failed to start reindexing"
    log "Reindexing started. This may take a while."
}

# Function to update Croissant exporter
update_croissant_exporter() {
    log "Checking if Croissant exporter is installed..."
    local croissant_installed
    croissant_installed=$(curl -s http://localhost:8080/api/admin/metadata/exporters | jq -r '.[] | select(.name == "croissant") | .name' 2>/dev/null || echo "")
    
    if [ -n "$croissant_installed" ]; then
        log "Croissant exporter found. Updating to v0.1.5..."
        read -p "Do you want to update the Croissant exporter to v0.1.5? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "Please follow the upgrade instructions at: https://github.com/gdcc/exporter-croissant"
            log "After upgrading, the script will reexport all dataset metadata."
            read -p "Press [Enter] after you have updated the Croissant exporter..."
            
            log "Reexporting all dataset metadata..."
            curl http://localhost:8080/api/admin/metadata/reExportAll
            check_error "Failed to reexport dataset metadata"
            log "Dataset metadata reexport completed."
        else
            log "Skipping Croissant exporter update."
        fi
    else
        log "Croissant exporter not found. Skipping update."
    fi
}

# Function to check archival bags configuration
check_archival_bags_config() {
    log "Checking archival bags configuration..."
    local jvm_options
    jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    if echo "$jvm_options" | grep -q "dataverse.bagit.sourceorg.name"; then
        log "✓ Archival bags configuration already set."
    else
        log "WARNING: dataverse.bagit.sourceorg.name JVM option is not set."
        log "If you use archival bags, you should set this option."
        read -p "Do you want to set the dataverse.bagit.sourceorg.name JVM option? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            read -p "Enter the source organization name for archival bags: " source_org
            if [ -n "$source_org" ]; then
                sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "-Ddataverse.bagit.sourceorg.name=$source_org"
                check_error "Failed to set archival bags configuration"
                log "Archival bags configuration set."
            else
                log "No source organization name provided. Skipping configuration."
            fi
        else
            log "Skipping archival bags configuration."
        fi
    fi
}

# Function to remind about Dataverse Previewers upgrade
remind_previewers_upgrade() {
    log "IMPORTANT: Dataverse Previewers should be upgraded to v1.5"
    log "This includes an updated video previewer that supports subtitles."
    log "Please follow the upgrade instructions at: https://github.com/gdcc/dataverse-previewers"
    log "The upgrade is required for proper VTT file support."
    read -p "Press [Enter] to acknowledge this reminder..."
}

# Function to remind about translation updates
remind_translation_updates() {
    log "REMINDER: If you use internationalization, please update translations"
    log "You can get the latest English files from: https://github.com/IQSS/dataverse/tree/v6.7/src/main/java/propertyFiles"
    log "For language packs, see: https://github.com/GlobalDataverseCommunityConsortium/dataverse-language-packs"
    read -p "Press [Enter] to acknowledge this reminder..."
}

# Main execution function
main() {
    log "Starting Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION..."
    
    if ! is_step_completed "PREFLIGHT_CHECKS"; then
        mark_step_as_running "PREFLIGHT_CHECKS"
        check_current_version
        check_error "Version check failed"
        read -p "Backup of database and configuration is strongly recommended. Proceed? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "Aborting."
            exit 0
        fi
        mark_step_as_complete "PREFLIGHT_CHECKS"
    fi

    if ! is_step_completed "UNDEPLOY_OLD_VERSION"; then
        mark_step_as_running "UNDEPLOY_OLD_VERSION"
        undeploy_dataverse
        mark_step_as_complete "UNDEPLOY_OLD_VERSION"
    fi

    if ! is_step_completed "STOP_PAYARA"; then
        mark_step_as_running "STOP_PAYARA"
        stop_service "payara"
        mark_step_as_complete "STOP_PAYARA"
    fi

    if ! is_step_completed "UPGRADE_PAYARA"; then
        mark_step_as_running "UPGRADE_PAYARA"
        upgrade_payara
        mark_step_as_complete "UPGRADE_PAYARA"
    fi

    if ! is_step_completed "DEPLOY_NEW_VERSION"; then
        mark_step_as_running "DEPLOY_NEW_VERSION"
        start_service "payara"
        sleep 60 # Give Payara time to start up
        deploy_dataverse
        mark_step_as_complete "DEPLOY_NEW_VERSION"
    fi

    if ! is_step_completed "POST_DEPLOY_CONFIG"; then
        mark_step_as_running "POST_DEPLOY_CONFIG"
        log "Pausing for 60 seconds to ensure application is fully initialized..."
        sleep 60
        
        migrate_api_filters
        redetect_vtt_files
        check_archival_bags_config
        remind_previewers_upgrade
        remind_translation_updates
        mark_step_as_complete "POST_DEPLOY_CONFIG"
    fi

    if ! is_step_completed "UPDATE_CROISSANT_EXPORTER"; then
        mark_step_as_running "UPDATE_CROISSANT_EXPORTER"
        update_croissant_exporter
        mark_step_as_complete "UPDATE_CROISSANT_EXPORTER"
    fi

    if ! is_step_completed "UPDATE_SOLR_SCHEMA"; then
        mark_step_as_running "UPDATE_SOLR_SCHEMA"
        update_solr_schema
        mark_step_as_complete "UPDATE_SOLR_SCHEMA"
    fi

    if ! is_step_completed "REINDEX"; then
        mark_step_as_running "REINDEX"
        start_service "payara"
        sleep 60
        reindex_data
        mark_step_as_complete "REINDEX"
    fi

    log "✅ Dataverse upgrade to $TARGET_VERSION completed successfully!"
}

main
