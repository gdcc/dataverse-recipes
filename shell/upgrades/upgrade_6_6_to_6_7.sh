#!/bin/bash
# set -x
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.7
#
# This script is designed to be enterprise-grade, production-ready, and suitable for
# distribution across institutions. It incorporates robust error handling, state
# management, and verification at each step to ensure a reliable and repeatable
# upgrade process.

# Version information
TARGET_VERSION="6.7.1"
CURRENT_VERSION="6.6"
PAYARA_VERSION="6.2025.3"
SOLR_VERSION="9.8.0" # No change from v6.6
REQUIRED_JAVA_VERSION="11" # No change from v6.6

# URLs for downloading files. Please note there's a mismatch between the WAR file version number. 
# The WAR file is 6.7.1, but ppaths for the other files are 6.7.
PAYARA_DOWNLOAD_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2025.3/payara-6.2025.3.zip"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.7.1/dataverse-6.7.1.war"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.7/conf/solr/schema.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.7/conf/solr/update-fields.sh"

# SHA256 checksums for verification
PAYARA_SHA256="88f5c1e5b40ea4bc60ae3e34e6858c1b33145dc06c4b05c3d318ed67c131e210"
DATAVERSE_WAR_SHA256="fd8d6010886e8a717bfa3d71c641a184004ad5c24d4d1f889294bd5b7c20b809"
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

# Usage information
show_usage() {
    echo "Dataverse 6.6 to 6.7 Upgrade Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --troubleshoot-indexing    Run indexing diagnostic and troubleshooting"
    echo "                              This will check database vs Solr consistency,"
    echo "                              identify indexing errors, and provide"
    echo "                              troubleshooting steps for common issues."
    echo ""
    echo "  --migrate-cors             Migrate CORS settings from database to JVM options"
    echo "                              This addresses CORS errors when uploading folders"
    echo "                              and follows the Filter-efficiency.md guidelines."
    echo ""
    echo "  --fix-uploader-cors        Fix CORS issues specifically for Dataverse Uploader"
    echo "                              This addresses CORS errors from gdcc.github.io"
    echo "                              and ensures proper CORS headers for preflight requests."
    echo ""
    echo "  --help                     Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                         Run the full upgrade process"
    echo "  $0 --troubleshoot-indexing Run indexing diagnostic only"
    echo "  $0 --migrate-cors          Migrate CORS settings only"
    echo "  $0 --fix-uploader-cors     Fix Dataverse Uploader CORS issues only"
    echo ""
    echo "The indexing diagnostic will help identify issues like:"
    echo "  • Datasets not appearing in search results"
    echo "  • Schema configuration problems"
    echo "  • Multi-valued field errors"
    echo "  • Indexing service failures"
    echo ""
    echo "The CORS migration will help resolve issues like:"
    echo "  • CORS errors when uploading folders"
    echo "  • Browser blocking of API requests"
    echo "  • Cross-origin resource sharing problems"
}

# Check for help argument
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

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

# Function to load environment variables
load_environment() {
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
}

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

    # Attempt deployment with retry logic
    local max_retries=2
    local attempt=1
    
    while [ $attempt -le $max_retries ]; do
        log "Deployment attempt $attempt of $max_retries..."
        
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" deploy "$WAR_FILE_LOCATION/$war_file"; then
            log "✅ Dataverse deployment successful on attempt $attempt"
            return 0
        else
            log "❌ Deployment attempt $attempt failed"
            
            if [ $attempt -lt $max_retries ]; then
                log "Clearing Payara cache directories and retrying..."
                stop_service "payara"
                
                # Clear problematic directories as mentioned in release notes
                sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated"
                sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache"
                sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases"
                
                start_service "payara"
                log "Waiting for Payara to fully start after cache clearing..."
                sleep 60
                
                attempt=$((attempt + 1))
            else
                log "❌ ERROR: All deployment attempts failed. Manual intervention may be required."
                return 1
            fi
        fi
    done
}

# Function to check if CORS migration is needed
check_cors_migration_needed() {
    log "Checking if CORS migration is needed..."
    
    local jvm_options
    jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    # Check if new CORS JVM options exist
    local has_cors_origin=false
    local has_cors_methods=false
    local has_cors_headers=false
    local has_cors_expose=false
    
    if echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
        has_cors_origin=true
    fi
    
    if echo "$jvm_options" | grep -q "dataverse.cors.methods"; then
        has_cors_methods=true
    fi
    
    if echo "$jvm_options" | grep -q "dataverse.cors.headers.allow"; then
        has_cors_headers=true
    fi
    
    if echo "$jvm_options" | grep -q "dataverse.cors.headers.expose"; then
        has_cors_expose=true
    fi
    
    if [[ "$has_cors_origin" == "true" && "$has_cors_methods" == "true" && "$has_cors_headers" == "true" && "$has_cors_expose" == "true" ]]; then
        log "✓ CORS JVM options already configured."
        return 0
    fi
    
    # Check if old database settings exist
    local allow_cors
    allow_cors=$(curl -s http://localhost:8080/api/admin/settings/:AllowCors 2>/dev/null || echo "null")
    
    if [[ "$allow_cors" == "true" || "$allow_cors" == "null" || "$allow_cors" == "{}" || -z "$allow_cors" ]]; then
        log "⚠️  CORS migration needed: AllowCors is enabled but JVM options not set"
        return 1
    else
        log "✓ CORS migration not needed: AllowCors is disabled"
        return 0
    fi
}

# Function to migrate API filters
migrate_api_filters() {
    log "Migrating API filter settings from database to JVM options..."

    # Check if new settings already exist
    local jvm_options
    jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    # Check for both API blocked policy and CORS settings
    local has_api_settings=false
    local has_cors_settings=false
    
    if echo "$jvm_options" | grep -q "dataverse.api.blocked.policy"; then
        has_api_settings=true
    fi
    
    if echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
        has_cors_settings=true
    fi
    
    if [[ "$has_api_settings" == "true" && "$has_cors_settings" == "true" ]]; then
        log "API filter and CORS JVM options already configured. Skipping migration."
        return 0
    fi

    log "Fetching old API filter settings..."
    local allow_cors
    allow_cors=$(curl -s http://localhost:8080/api/admin/settings/:AllowCors)
    # If allow_cors is not set, prompt the user to set it
    if [ -z "$allow_cors" ]; then
        log "AllowCors is not set. Please set it to true in the database."
        read -p "Do you want to set AllowCors to true? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            curl -X PUT http://localhost:8080/api/admin/settings/:AllowCors -d 'true'
            check_error "Failed to set AllowCors"
        else
            log "Skipping AllowCors setting."
        fi
    fi

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

    # Handle CORS configuration according to Filter-efficiency.md
    # If :AllowCors is not set or is true, set CORS origin to *
    if [[ "$allow_cors" == "true" || "$allow_cors" == "null" || "$allow_cors" == "{}" || -z "$allow_cors" ]]; then
        log "Setting CORS configuration (allowing all origins)..."
        
        # Set CORS origin - use * to allow all origins including gdcc.github.io
        if ! echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.origin=*"
            check_error "Failed to set CORS origin"
        else
            log "CORS origin JVM option already exists. Skipping."
        fi
        
        # Set CORS methods (optional, defaults to common methods)
        if ! echo "$jvm_options" | grep -q "dataverse.cors.methods"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.methods=GET,POST,PUT,DELETE,OPTIONS"
            check_error "Failed to set CORS methods"
        else
            log "CORS methods JVM option already exists. Skipping."
        fi
        
        # Set CORS allowed headers (optional, includes common headers)
        if ! echo "$jvm_options" | grep -q "dataverse.cors.headers.allow"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.headers.allow=Content-Type,X-Requested-With,Accept,Origin,Access-Control-Request-Method,Access-Control-Request-Headers,X-Dataverse-key,X-Dataverse-unblock-key"
            check_error "Failed to set CORS allowed headers"
        else
            log "CORS allowed headers JVM option already exists. Skipping."
        fi
        
        # Set CORS exposed headers (important for Dataverse Uploader)
        if ! echo "$jvm_options" | grep -q "dataverse.cors.headers.expose"; then
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.headers.expose=Access-Control-Allow-Origin,Access-Control-Allow-Methods,Access-Control-Allow-Headers,X-Dataverse-key,X-Dataverse-unblock-key"
            check_error "Failed to set CORS exposed headers"
        else
            log "CORS exposed headers JVM option already exists. Skipping."
        fi
        
    else
        log "CORS is currently disabled (AllowCors=$allow_cors). CORS configuration not set."
        log "If you need CORS enabled, you can manually set it later with:"
        log "  sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin create-jvm-options '-Ddataverse.cors.origin=*'"
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
    
    # Verify the migration was successful
    log "Verifying migration results..."
    local final_jvm_options
    final_jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    log "📋 Migration Summary:"
    if echo "$final_jvm_options" | grep -q "dataverse.cors.origin"; then
        log "  ✅ CORS origin configured"
    else
        log "  ⚠️  CORS origin not configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.cors.methods"; then
        log "  ✅ CORS methods configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.cors.headers.allow"; then
        log "  ✅ CORS allowed headers configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.cors.headers.expose"; then
        log "  ✅ CORS exposed headers configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.api.blocked.endpoints"; then
        log "  ✅ API blocked endpoints configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.api.blocked.policy"; then
        log "  ✅ API blocked policy configured"
    fi
    
    if echo "$final_jvm_options" | grep -q "dataverse.api.blocked.key"; then
        log "  ✅ API blocked key configured"
    fi
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

# Function to handle internationalization updates
handle_internationalization_updates() {
    log "Checking internationalization configuration..."
    
    read -p "Do you use language packs or custom translations? (y/N): " use_i18n
    if [[ "$use_i18n" =~ ^[Yy]$ ]]; then
        log "IMPORTANT: You need to update your language packs and translations for Dataverse 6.7"
        log ""
        log "For language packs, see: https://github.com/GlobalDataverseCommunityConsortium/dataverse-language-packs"
        log "For custom translations, get the latest English files from: https://github.com/IQSS/dataverse/tree/v6.7/src/main/java/propertyFiles"
        log ""
        log "The upgrade script will continue, but you should update your translations after the upgrade is complete."
        log "Failure to update translations may result in missing or outdated text in your Dataverse interface."
        log ""
        read -p "Do you want to exit the script now to update translations first? (y/N): " exit_for_translations
        if [[ "$exit_for_translations" =~ ^[Yy]$ ]]; then
            log "Exiting upgrade script. Please update your translations and run the script again."
            exit 0
        else
            log "Continuing with upgrade. Remember to update translations after completion."
        fi
    else
        log "No internationalization in use. Skipping translation update reminders."
    fi
}

# Function to check for required system commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "grep" "sed" "sudo" "systemctl" "pgrep" "jq" "rm" "ls" "bash" "tee" "sha256sum" "wget" "unzip" "java" "xmllint" "bc"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "❌ Error: The following required commands are not installed:"
        printf ' - %s\n' "${missing_commands[@]}" | tee -a "$LOGFILE"
        echo
        log "Please install these commands before running the script."
        exit 1
    fi
}

# Function to verify database vs Solr indexing consistency
verify_indexing_consistency() {
    log "🔍 Verifying database vs Solr indexing consistency..."
    
    # Get database counts
    local db_datasets=$(sudo -u postgres psql -d dvndb -t -c "SELECT COUNT(*) FROM dvobject WHERE dtype = 'Dataset';" 2>/dev/null | xargs || echo "0")
    local db_published_datasets=$(sudo -u postgres psql -d dvndb -t -c "SELECT COUNT(*) FROM dvobject WHERE dtype = 'Dataset' AND publicationdate IS NOT NULL;" 2>/dev/null | xargs || echo "0")
    local db_dataverses=$(sudo -u postgres psql -d dvndb -t -c "SELECT COUNT(*) FROM dvobject WHERE dtype = 'Dataverse';" 2>/dev/null | xargs || echo "0")
    
    # Get Solr counts
    local solr_total=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
    local solr_datasets=$(curl -s "http://localhost:8983/solr/collection1/select?q=dvObjectType:datasets&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
    local solr_dataverses=$(curl -s "http://localhost:8983/solr/collection1/select?q=dvObjectType:dataverses&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
    
    # Log the counts
    log "📊 Database Counts:"
    log "  • Total Datasets: $db_datasets"
    log "  • Published Datasets: $db_published_datasets"
    log "  • Dataverses: $db_dataverses"
    
    log "🔍 Solr Index Counts:"
    log "  • Total Documents: $solr_total"
    log "  • Indexed Datasets: $solr_datasets"
    log "  • Indexed Dataverses: $solr_dataverses"
    
    # Check for discrepancies
    local dataset_discrepancy=$((db_published_datasets - solr_datasets))
    local dataverse_discrepancy=$((db_dataverses - solr_dataverses))
    
    # Analyze the discrepancies more intelligently
    if [ "$dataset_discrepancy" -eq 0 ] && [ "$dataverse_discrepancy" -eq 0 ]; then
        log "✅ Indexing consistency verified - all published datasets and dataverses are indexed"
        return 0
    else
        log "📊 INDEXING ANALYSIS:"
        
        # Dataset analysis
        if [ "$dataset_discrepancy" -lt 0 ]; then
            log "  ✅ Dataset indexing: EXCELLENT"
            log "    • Solr has $((solr_datasets - db_published_datasets)) more datasets than published"
            log "    • This is normal - Solr indexes ALL datasets (published + unpublished + drafts)"
        elif [ "$dataset_discrepancy" -gt 0 ]; then
            log "  ⚠️  Dataset discrepancy: $dataset_discrepancy published datasets not indexed"
            log "    (Database: $db_published_datasets published, Solr: $solr_datasets indexed)"
        else
            log "  ✅ Dataset indexing: PERFECT"
        fi
        
        # Dataverse analysis  
        if [ "$dataverse_discrepancy" -eq 0 ]; then
            log "  ✅ Dataverse indexing: PERFECT"
        elif [ "$dataverse_discrepancy" -eq 1 ]; then
            log "  ⚠️  Dataverse indexing: MINOR ISSUE"
            log "    • Only 1 dataverse missing (likely newly created or temporary indexing issue)"
            log "    (Database: $db_dataverses total, Solr: $solr_dataverses indexed)"
        else
            log "  ⚠️  Dataverse discrepancy: $dataverse_discrepancy dataverses not indexed"
            log "    (Database: $db_dataverses total, Solr: $solr_dataverses indexed)"
        fi
        
        # Provide troubleshooting steps
        log ""
        log "🔧 TROUBLESHOOTING STEPS:"
        log "  1. Check for indexing errors in Payara logs:"
        log "     tail -50 $PAYARA/glassfish/domains/domain1/logs/server.log"
        log "  2. Verify Solr schema configuration:"
        log "     grep -i 'multiValued' $SOLR_PATH/server/solr/collection1/conf/schema.xml"
        log "  3. Check for specific dataset indexing failures:"
        log "     grep 'ERROR.*dataset_' $PAYARA/glassfish/domains/domain1/logs/server.log"
        log "  4. Trigger manual reindex if needed:"
        log "     curl \"http://localhost:8080/api/admin/index/clear\" -H \"X-Dataverse-key: YOUR_API_KEY\""
        log "     curl \"http://localhost:8080/api/admin/index\" -H \"X-Dataverse-key: YOUR_API_KEY\""
        
        return 1
    fi
}

# Function to check for specific indexing errors
check_indexing_errors() {
    log "🔍 Checking for indexing errors in recent logs..."
    
    local error_count=$(sudo grep -c "ERROR.*dataset_" "$PAYARA/glassfish/domains/domain1/logs/server.log" 2>/dev/null || echo "0")
    local multi_valued_errors=$(sudo grep -c "multiple values encountered for non multiValued field" "$PAYARA/glassfish/domains/domain1/logs/server.log" 2>/dev/null || echo "0")
    
    # Clean the values to ensure they are integers
    error_count=$(echo "$error_count" | tr -d '\n\r\t ' | head -1)
    multi_valued_errors=$(echo "$multi_valued_errors" | tr -d '\n\r\t ' | head -1)
    
    # Validate that they are integers
    if ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
        error_count="0"
    fi
    if ! [[ "$multi_valued_errors" =~ ^[0-9]+$ ]]; then
        multi_valued_errors="0"
    fi
    
    if [ "$error_count" -eq 0 ] && [ "$multi_valued_errors" -eq 0 ]; then
        log "✅ No indexing errors detected in recent logs"
        return 0
    else
        log "⚠️  INDEXING ERRORS DETECTED:"
        log "  • Total dataset indexing errors: $error_count"
        log "  • Multi-valued field errors: $multi_valued_errors"
        
        if [ "$multi_valued_errors" -gt 0 ]; then
            log ""
            log "🔧 MULTI-VALUED FIELD ERROR DETECTED:"
            log "  This indicates schema configuration issues. Common fixes:"
            log "  1. Check schema.xml for fields that should be multiValued=\"true\":"
            log "     sudo grep -A 2 -B 2 'multiValued=\"false\"' $SOLR_PATH/server/solr/collection1/conf/schema.xml"
            log "  2. Update problematic fields to multiValued=\"true\""
            log "  3. Restart Solr: sudo systemctl restart solr"
            log "  4. Clear and rebuild index"
        fi
        
        # Show recent errors
        log ""
        log "📋 Recent indexing errors:"
        sudo grep "ERROR.*dataset_" "$PAYARA/glassfish/domains/domain1/logs/server.log" 2>/dev/null | tail -3 | while read -r line; do
            log "  • $line"
        done
        
        return 1
    fi
}

# Function to check Dataverse Uploader CORS compatibility
check_uploader_cors() {
    log "🔍 Checking Dataverse Uploader CORS compatibility..."
    
    # Test CORS headers for gdcc.github.io
    local cors_test=$(curl -s -I -H "Origin: https://gdcc.github.io" \
        -H "Access-Control-Request-Method: GET" \
        -H "Access-Control-Request-Headers: X-Dataverse-key" \
        -X OPTIONS \
        "http://localhost:8080/api/info/version" 2>/dev/null)
    
    if echo "$cors_test" | grep -q "Access-Control-Allow-Origin"; then
        log "✅ CORS headers are properly set for Dataverse Uploader"
        return 0
    else
        log "⚠️  CORS headers may not be properly configured for Dataverse Uploader"
        return 1
    fi
}

# Function to fix Dataverse Uploader CORS issues
fix_uploader_cors() {
    log "========================================="
    log "🔧 DATAVERSE UPLOADER CORS FIX"
    log "========================================="
    
    # Check service status
    log "📋 Service Status:"
    local payara_status=$(systemctl is-active payara 2>/dev/null || echo "unknown")
    log "  • Payara: $payara_status"
    
    if [[ "$payara_status" != "active" ]]; then
        log "❌ ERROR: Payara is not running. Please start Payara first:"
        log "  sudo systemctl start payara"
        return 1
    fi
    
    log "🔍 Current CORS configuration:"
    local jvm_options
    jvm_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    # Check current CORS settings
    if echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
        log "  ✅ CORS origin is configured"
        local current_origin=$(echo "$jvm_options" | grep "dataverse.cors.origin" | sed 's/.*dataverse.cors.origin=//')
        log "  📍 Current origin setting: $current_origin"
    else
        log "  ❌ CORS origin is not configured"
    fi
    
    if echo "$jvm_options" | grep -q "dataverse.cors.headers.expose"; then
        log "  ✅ CORS exposed headers are configured"
    else
        log "  ❌ CORS exposed headers are not configured"
    fi
    
    # Test current CORS functionality
    log ""
    log "🔍 Testing current CORS functionality..."
    if check_uploader_cors; then
        log "✅ CORS is working correctly for Dataverse Uploader"
        log "No fixes needed."
        return 0
    fi
    
    log "⚠️  CORS issues detected. Applying fixes..."
    
    # Ensure CORS origin is set to allow all origins (including gdcc.github.io)
    if ! echo "$jvm_options" | grep -q "dataverse.cors.origin"; then
        log "Setting CORS origin to allow all origins..."
        sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.origin=*"
        check_error "Failed to set CORS origin"
    else
        local current_origin=$(echo "$jvm_options" | grep "dataverse.cors.origin" | sed 's/.*dataverse.cors.origin=//')
        if [[ "$current_origin" != "*" ]]; then
            log "Updating CORS origin to allow all origins..."
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" delete-jvm-options -- "-Ddataverse.cors.origin=$current_origin"
            sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.origin=*"
            check_error "Failed to update CORS origin"
        fi
    fi
    
    # Ensure CORS exposed headers are set
    if ! echo "$jvm_options" | grep -q "dataverse.cors.headers.expose"; then
        log "Setting CORS exposed headers..."
        sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options -- "-Ddataverse.cors.headers.expose=Access-Control-Allow-Origin,Access-Control-Allow-Methods,Access-Control-Allow-Headers,X-Dataverse-key,X-Dataverse-unblock-key"
        check_error "Failed to set CORS exposed headers"
    fi
    
    # Restart Payara to apply changes
    log "Restarting Payara to apply CORS fixes..."
    stop_service "payara"
    start_service "payara"
    log "Waiting for Payara to fully start..."
    sleep 30
    
    # Test the fix
    log ""
    log "🔍 Testing CORS fix..."
    if check_uploader_cors; then
        log "✅ CORS fix successful! Dataverse Uploader should now work."
    else
        log "⚠️  CORS fix may not be complete. Please check:"
        log "  1. Browser developer console for specific error messages"
        log "  2. Payara logs: tail -50 $PAYARA/glassfish/domains/domain1/logs/server.log"
        log "  3. Manual test: curl -I -H 'Origin: https://gdcc.github.io' http://localhost:8080/api/info/version"
    fi
    
    log "========================================="
    log "✅ DATAVERSE UPLOADER CORS FIX COMPLETE"
    log "========================================="
}

# Standalone function for CORS migration
migrate_cors_standalone() {
    log "========================================="
    log "🌐 CORS MIGRATION UTILITY"
    log "========================================="
    
    # Check service status
    log "📋 Service Status:"
    local payara_status=$(systemctl is-active payara 2>/dev/null || echo "unknown")
    log "  • Payara: $payara_status"
    
    if [[ "$payara_status" != "active" ]]; then
        log "❌ ERROR: Payara is not running. Please start Payara first:"
        log "  sudo systemctl start payara"
        return 1
    fi
    
    # Check if migration is needed
    log ""
    if check_cors_migration_needed; then
        log "✅ CORS migration not needed - settings are already properly configured."
        
        # Still check Dataverse Uploader compatibility
        log ""
        check_uploader_cors
        
        return 0
    fi
    
    log "⚠️  CORS migration is needed. This will:"
    log "  • Check current CORS settings in database"
    log "  • Migrate settings to JVM options (more efficient)"
    log "  • Restart Payara to apply changes"
    log "  • Clean up old database settings"
    log "  • Test Dataverse Uploader compatibility"
    log ""
    read -p "Do you want to proceed with CORS migration? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "CORS migration cancelled."
        return 0
    fi
    
    # Run the migration
    log ""
    migrate_api_filters
    
    # Test Dataverse Uploader compatibility after migration
    log ""
    log "Testing Dataverse Uploader compatibility..."
    sleep 10  # Give Payara time to fully start
    check_uploader_cors
    
    log "========================================="
    log "✅ CORS MIGRATION COMPLETE"
    log "========================================="
    log ""
    log "If you're still experiencing CORS errors, check:"
    log "  1. Browser developer console for specific error messages"
    log "  2. Payara logs: tail -50 $PAYARA/glassfish/domains/domain1/logs/server.log"
    log "  3. Verify JVM options: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin list-jvm-options | grep cors"
    log "  4. Test CORS manually: curl -I -H 'Origin: https://gdcc.github.io' http://localhost:8080/api/info/version"
}

# Standalone function for troubleshooting indexing issues
troubleshoot_indexing() {
    log "========================================="
    log "🔍 INDEXING TROUBLESHOOTING DIAGNOSTIC"
    log "========================================="
    
    # Check service status
    log "📋 Service Status:"
    local payara_status=$(systemctl is-active payara 2>/dev/null || echo "unknown")
    local solr_status=$(systemctl is-active solr 2>/dev/null || echo "unknown")
    log "  • Payara: $payara_status"
    log "  • Solr: $solr_status"
    
    # Run indexing consistency check
    log ""
    verify_indexing_consistency
    
    # Check for indexing errors
    log ""
    check_indexing_errors
    
    # Check recent indexing activity
    log ""
    log "📊 Recent Indexing Activity:"
    local recent_indexing=$(sudo grep "indexing dataset" "$PAYARA/glassfish/domains/domain1/logs/server.log" 2>/dev/null | tail -5 || echo "No recent indexing activity found")
    if [[ "$recent_indexing" != "No recent indexing activity found" ]]; then
        echo "$recent_indexing" | while read -r line; do
            log "  • $line"
        done
    else
        log "  • $recent_indexing"
    fi
    
    # Check Solr schema for potential issues
    log ""
    log "🔧 Solr Schema Analysis:"
    local problematic_fields=$(sudo grep -A 2 -B 2 'multiValued="false"' "$SOLR_PATH/server/solr/collection1/conf/schema.xml" 2>/dev/null | grep -E "(sw|software|artifact)" | head -5 || echo "No potentially problematic fields found")
    if [[ "$problematic_fields" != "No potentially problematic fields found" ]]; then
        log "  ⚠️  Potentially problematic fields (check if these should be multiValued=\"true\"):"
        echo "$problematic_fields" | while read -r line; do
            log "    • $line"
        done
    else
        log "  • $problematic_fields"
    fi
    
    log "========================================="
    log "✅ INDEXING DIAGNOSTIC COMPLETE"
    log "========================================="
}

# Main execution function
main() {
    # Only proceed with version check for full upgrade
    load_environment
    log "Starting Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION..."
    
    if ! is_step_completed "PREFLIGHT_CHECKS"; then
        mark_step_as_running "PREFLIGHT_CHECKS"
        check_required_commands
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
        handle_internationalization_updates
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

# Check for command-line arguments first (before calling main)
if [[ "$1" == "--troubleshoot-indexing" ]]; then
    troubleshoot_indexing
    exit 0
fi

if [[ "$1" == "--migrate-cors" ]]; then
    load_environment
    migrate_cors_standalone
    exit 0
fi

if [[ "$1" == "--fix-uploader-cors" ]]; then
    load_environment
    fix_uploader_cors
    exit 0
fi

main
