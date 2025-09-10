#!/bin/bash

# Dataverse Production Backup & Fetch Script
# Automates syncing a Dataverse instance from production to a staging/clone server
# Handles database backup, files, Solr configuration, counter processor components

# Get the directory of the script itself
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Logging configuration
LOGFILE="${SCRIPT_DIR}/fetching_prod_backup.log"
echo "" > "$LOGFILE"

# Global variables for S3 configuration
S3_CONFIG_CHOICE=""
INPUT_CLONE_S3_BUCKET_NAME="${INPUT_CLONE_S3_BUCKET_NAME:-jhu-dataverse-clone}"
INPUT_CLONE_S3_ACCESS_KEY="${INPUT_CLONE_S3_ACCESS_KEY:-}"
INPUT_CLONE_S3_SECRET_KEY="${INPUT_CLONE_S3_SECRET_KEY:-}"
INPUT_CLONE_S3_REGION="${INPUT_CLONE_S3_REGION:-us-east-2}"

# Global variables for S3 JVM options summary
PROD_S3_OPTIONS=()
PROD_S3_DUPLICATES=()
LOCAL_S3_OPTIONS=()
LOCAL_S3_DUPLICATES=()

# Global warnings array
WARNINGS=()

ITEMS_TO_REINDEX=0

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to log warnings
log_warning() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - WARNING: $1" | tee -a "$LOGFILE"
}

# Function to fetch production JVM S3 options early
pre_sync_fetch_prod_jvm_s3_options() {
    log "Fetching production JVM options for S3 configuration analysis..."
    
    # Check if production server variables are set
    if [ -z "$PRODUCTION_SSH_USER" ] || [ -z "$PRODUCTION_SERVER" ] || [ -z "$PRODUCTION_DATAVERSE_USER" ]; then
        log_warning "Production server variables not fully set. Skipping early S3 JVM options fetch."
        return 0
    fi
    
    # Get production JVM options for S3 analysis
    if ssh -o ConnectTimeout=10 "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "command -v /usr/local/payara6/bin/asadmin" >/dev/null 2>&1; then
        PROD_PAYARA_PATH="/usr/local/payara6"
    elif ssh -o ConnectTimeout=10 "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "command -v $PAYARA/bin/asadmin" >/dev/null 2>&1; then
        PROD_PAYARA_PATH="$PAYARA"
    else
        log_warning "Could not determine production Payara path. S3 configuration analysis may be limited."
        return 0
    fi
    
    local prod_jvm_options
    prod_jvm_options=$(ssh -o ConnectTimeout=10 "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u $PRODUCTION_DATAVERSE_USER $PROD_PAYARA_PATH/bin/asadmin list-jvm-options 2>/dev/null")
    
    if [ -n "$prod_jvm_options" ]; then
        log "Successfully fetched production JVM options for analysis."
        scan_s3_jvm_options "$prod_jvm_options" true # true for production
    else
        log_warning "Could not fetch production JVM options. S3 configuration analysis will be limited."
    fi
}

# Function to check version compatibility
check_versions() {
    log "Checking version compatibility between production and local..."
    
    # Check local Payara version
    if [ -n "$PAYARA" ] && [ -f "$PAYARA/bin/asadmin" ]; then
        LOCAL_PAYARA_VERSION=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" version 2>/dev/null | head -1 | grep -oP 'Payara Server \K[0-9]+\.[0-9]+' || echo "unknown")
        log "Local Payara version: $LOCAL_PAYARA_VERSION"
    else
        log_warning "Could not determine local Payara version"
        LOCAL_PAYARA_VERSION="unknown"
    fi
    
    # Check production Payara version if possible
    if [ -n "$PRODUCTION_SSH_USER" ] && [ -n "$PRODUCTION_SERVER" ] && [ -n "$PROD_PAYARA_PATH" ]; then
        PROD_PAYARA_VERSION=$(ssh -o ConnectTimeout=10 "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u $PRODUCTION_DATAVERSE_USER $PROD_PAYARA_PATH/bin/asadmin version 2>/dev/null | head -1 | grep -oP 'Payara Server \K[0-9]+\.[0-9]+'" 2>/dev/null || echo "unknown")
        log "Production Payara version: $PROD_PAYARA_VERSION"
    else
        log_warning "Could not determine production Payara version"
        PROD_PAYARA_VERSION="unknown"
    fi
    
    # Check for version compatibility
    if [ "$LOCAL_PAYARA_VERSION" != "unknown" ] && [ "$PROD_PAYARA_VERSION" != "unknown" ]; then
        if [ "$LOCAL_PAYARA_VERSION" != "$PROD_PAYARA_VERSION" ]; then
            log_warning "Payara version mismatch detected!"
            log_warning "Production: $PROD_PAYARA_VERSION, Local: $LOCAL_PAYARA_VERSION"
            log_warning "This may cause compatibility issues with JVM options and configurations."
        else
            log "Payara versions match: $LOCAL_PAYARA_VERSION"
        fi
    fi
}

# Function to wait for Dataverse reindex to complete
wait_for_dataverse_reindex_api() {
    local items_to_reindex="$1"
    local max_wait=1800  # 30 minutes
    local interval=30
    local elapsed=0
    
    log "Waiting for Dataverse reindex to complete ($items_to_reindex items)..."
    
    while [ $elapsed -lt $max_wait ]; do
        # Check if reindex is still running
        local index_status
        index_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
        
        if [ -n "$index_status" ]; then
            # Check if indexing is still in progress
            if echo "$index_status" | grep -q '"isIndexing":false'; then
                log "Dataverse reindex completed successfully."
                return 0
            fi
        fi
        
        log "Reindex still in progress... (elapsed: ${elapsed}s/${max_wait}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_warning "Timed out waiting for reindex to complete after ${max_wait} seconds."
    return 1
}

# Function to print help message
print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Dataverse Production Backup & Fetch Script"
    echo "Automates syncing a Dataverse instance from production to a staging/clone server"
    echo ""
    echo "Options:"
    echo "  --dry-run               Show what would be done without making changes"
    echo "  --verbose               Show detailed output"
    echo "  --debug                 Show debug output"
    echo "  --skip-db               Skip database sync"
    echo "  --skip-files            Skip files sync"
    echo "  --skip-solr             Skip Solr sync"
    echo "  --skip-counter          Skip counter processor sync"
    echo "  --skip-backup           Skip backup of clone server before sync"
    echo "  --skip-external-tools   Skip external tools sync"
    echo "  --skip-jvm-options      Skip JVM options sync"
    echo "  --skip-post-setup       Skip post-transfer setup"
    echo "  --skip-template-check   Skip template integrity check"
    echo "  --cleanup-backups       Clean up old backups before starting"
    echo "  --restore               Restore from backup"
    echo "  --restore-path=PATH     Specify backup path for restore"
    echo "  --full-copy             Perform full file sync (no size limit)"
    echo "  --configure-ddl         Configure Payara DDL settings"
    echo "  --compare-configs       Compare domain.xml between production and local"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Environment variables must be set in .env file in script directory."
}

# Function to print final summary
print_final_summary() {
    local is_dry_run="$1"
    echo ""
    log "=== FINAL EXECUTION SUMMARY ==="
    if [ "$is_dry_run" = true ]; then
        log "🧪 DRY RUN COMPLETED"
    fi
    
    # Define status icons
    local icon_success="✅"
    local icon_failure="❌"
    local icon_skipped="⏭️"
    local icon_dry_run="🧪"
    
    # Print status for each component
    log "Database Sync: ${STATUS_DATABASE:+$icon_success} ${STATUS_DATABASE:-$icon_skipped} ${STATUS_DATABASE:-SKIPPED}"
    log "Files Sync: ${STATUS_FILES:+$icon_success} ${STATUS_FILES:-$icon_skipped} ${STATUS_FILES:-SKIPPED}"
    log "Solr Sync: ${STATUS_SOLR:+$icon_success} ${STATUS_SOLR:-$icon_skipped} ${STATUS_SOLR:-SKIPPED}"
    log "Counter Processor: ${STATUS_COUNTER:+$icon_success} ${STATUS_COUNTER:-$icon_skipped} ${STATUS_COUNTER:-SKIPPED}"
    log "External Tools: ${STATUS_EXTERNAL_TOOLS:+$icon_success} ${STATUS_EXTERNAL_TOOLS:-$icon_skipped} ${STATUS_EXTERNAL_TOOLS:-SKIPPED}"
    log "JVM Options: ${STATUS_JVM_OPTIONS:+$icon_success} ${STATUS_JVM_OPTIONS:-$icon_skipped} ${STATUS_JVM_OPTIONS:-SKIPPED}"
    log "Post-Setup: ${STATUS_POST_SETUP:+$icon_success} ${STATUS_POST_SETUP:-$icon_skipped} ${STATUS_POST_SETUP:-SKIPPED}"
    log "Template Check: ${STATUS_TEMPLATE_CHECK:+$icon_success} ${STATUS_TEMPLATE_CHECK:-$icon_skipped} ${STATUS_TEMPLATE_CHECK:-SKIPPED}"
    
    # Print overall status
    if [ "$SCRIPT_OVERALL_STATUS" = "SUCCESS" ]; then
        log "Overall Status: $icon_success SUCCESS"
    else
        log "Overall Status: $icon_failure FAILURE"
    fi

    # Print S3 Configuration Summary
    echo ""
    log "=== S3 CONFIGURATION SUMMARY ==="
    
    # Production S3 Options
    if [ ${#PROD_S3_OPTIONS[@]} -gt 0 ]; then
        log "Production S3-related JVM Options:"
        for option in "${PROD_S3_OPTIONS[@]}"; do
            log "  - $option"
        done
        
        if [ ${#PROD_S3_DUPLICATES[@]} -gt 0 ]; then
            log "⚠️  Production S3 Duplicate Properties:"
            for dup in "${PROD_S3_DUPLICATES[@]}"; do
                log "  - $dup"
                # Show all values for this property
                grep -- "-D${dup}=" <<< "${PROD_S3_OPTIONS[*]}" | while read -r value; do
                    log "    * $value"
                done
            done
        fi
    else
        log "No S3-related JVM options found in production configuration. This might be a false positive."
    fi
    
    # Local S3 Options
    if [ ${#LOCAL_S3_OPTIONS[@]} -gt 0 ]; then
        log "Local S3-related JVM Options:"
        for option in "${LOCAL_S3_OPTIONS[@]}"; do
            log "  - $option"
        done
        
        if [ ${#LOCAL_S3_DUPLICATES[@]} -gt 0 ]; then
            log "⚠️  Local S3 Duplicate Properties:"
            for dup in "${LOCAL_S3_DUPLICATES[@]}"; do
                log "  - $dup"
                # Show all values for this property
                grep -- "-D${dup}=" <<< "${LOCAL_S3_OPTIONS[*]}" | while read -r value; do
                    log "    * $value"
                done
            done
        fi
    else
        log "No S3-related JVM options found in local configuration. This might be a false positive."
    fi

    # Print warnings if any
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo ""
        log "=== WARNINGS ==="
        for w in "${WARNINGS[@]}"; do
            log "$w"
        done
    fi
}

log "Script directory is: $SCRIPT_DIR"

# Load environment variables
if [ -f "${SCRIPT_DIR}/.env" ]; then
    log "Found .env file at ${SCRIPT_DIR}/.env"
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
    log "Environment variables loaded"
    log "DB_SYSTEM_USER=${DB_SYSTEM_USER}"
    log "DB_NAME=${DB_NAME}"
    log "DB_USER=${DB_USER}"
else
    log "No .env file found at ${SCRIPT_DIR}/.env"
fi

# Function to check for errors and exit if found
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1. Exiting."
        exit 1
    fi
}

# Function to check network connectivity to a host
check_network_connectivity() {
    local host="$1"
    if ! ping -c 1 -W 5 "$host" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Function to verify SSH connectivity
verify_ssh_connectivity() {
    local ssh_target="$1"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_target" "echo Connection successful" &>/dev/null; then
        return 1
    fi
    return 0
}

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "rsync" "ssh" "psql" "pg_dump" "sed" "systemctl" "sudo" "jq"
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
    
    # Check for Docker/container environment
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        log "Detected Docker container environment."
        IS_DOCKER=true
    else
        IS_DOCKER=false
    fi
}

# Function to check SSL certificate validity
check_ssl_certificates() {
    echo ""
    log "=== SSL CERTIFICATE VALIDITY ==="
    local domain="$1"
    local cert_file
    cert_file=$(mktemp)
    
    if ! openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -text > "$cert_file" 2>/dev/null; then
        log "Warning: Could not retrieve SSL certificate for $domain"
        rm -f "$cert_file"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(grep "Not After" "$cert_file" | cut -d: -f2- | xargs)
    log "SSL certificate expiry date: $expiry_date"
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s)
    local current_epoch
    current_epoch=$(date +%s)
    
    rm -f "$cert_file"
    
    if [ "$current_epoch" -ge "$expiry_epoch" ]; then
        log "Warning: SSL certificate for $domain has expired. Expired on $expiry_date"
        CERT_EXPIRED=true
        return 1
    fi
    
    return 0
}

# Function to check required environment variables
check_required_vars() {
    local context="$1"
    shift
    local missing_vars=()
    
    for var in "$@"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        log "Error: The following required variables for $context are not set in .env file:"
        printf ' - %s\n' "${missing_vars[@]}" | tee -a "$LOGFILE"
        return 1
    fi
    
    return 0
}

# Function to check directory space and writability
check_dir_space_and_writable() {
    local context="$1"
    local dir="$2"
    local required_space="$3"
    
    # Check if directory exists and is writable
    if [ ! -d "$dir" ]; then
        log "Error: Directory $dir does not exist for $context"
        return 1
    fi
    
    if [ ! -w "$dir" ]; then
        log "Error: Directory $dir is not writable for $context"
        return 1
    fi
    
    # Check available space
    local available_space
    available_space=$(df -B1 "$dir" | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "Error: Insufficient space in $dir for $context"
        log "Required: $((required_space / 1024 / 1024)) MB"
        log "Available: $((available_space / 1024 / 1024)) MB"
        return 1
    fi
    
    return 0
}

# Function to check available space in a directory
check_available_space() {
    local dir="$1"
    local required_space="$2"
    local available_space
    
    available_space=$(df -B1 "$dir" | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "Error: Insufficient space in $dir"
        log "Required: $((required_space / 1024 / 1024)) MB"
        log "Available: $((available_space / 1024 / 1024)) MB"
        return 1
    fi
    return 0
}

# Function to find directory with sufficient space
find_sufficient_space() {
    local required_space="$1"
    local potential_dirs=(
        "/tmp"
        "/var/tmp"
        "/home/dricha73"
        "/home"
        "/var"
    )
    
    for dir in "${potential_dirs[@]}"; do
        if [ -d "$dir" ] && [ -w "$dir" ]; then
            if check_available_space "$dir" "$required_space"; then
                echo "$dir"
                return 0
            fi
        fi
    done
    
    return 1
}

# Function to clean up old backups
cleanup_old_backups() {
    local backup_dir="$1"
    local max_age_days=7
    
    log "Cleaning up backups older than $max_age_days days..."
    find "$backup_dir" -maxdepth 1 -type d -name "dataverse_clone_backup_*" -mtime +$max_age_days -exec rm -rf {} \;
}

# Function to create backup
create_backup() {
    log "Creating backup of clone server before syncing from production..."
    
    # Estimate size of local database
    LOCAL_DUMP_SIZE_EST=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -t -c "SELECT pg_database_size('$DB_NAME');" | tr -d '[:space:]')
    if [ -z "$LOCAL_DUMP_SIZE_EST" ]; then
        log "ERROR: Could not estimate size of local database. Aborting."
        return 1
    fi
    
    # Add 20% safety margin
    LOCAL_DUMP_SIZE_EST=$((LOCAL_DUMP_SIZE_EST + LOCAL_DUMP_SIZE_EST / 5))
    
    # Try to find a directory with sufficient space
    BACKUP_DIR="$HOME/dataverse_clone_backup_$(date +"%Y%m%d")"
    if ! check_available_space "$HOME" "$LOCAL_DUMP_SIZE_EST"; then
        log "Insufficient space in home directory. Looking for alternative location..."
        ALTERNATIVE_DIR=$(find_sufficient_space "$LOCAL_DUMP_SIZE_EST")
        if [ -n "$ALTERNATIVE_DIR" ]; then
            BACKUP_DIR="$ALTERNATIVE_DIR/dataverse_clone_backup_$(date +"%Y%m%d")"
            log "Found alternative backup location: $BACKUP_DIR"
        else
            log "ERROR: Could not find any directory with sufficient space. Required: $((LOCAL_DUMP_SIZE_EST / 1024 / 1024)) MB"
            return 1
        fi
    fi
    
    if [ -d "$BACKUP_DIR" ]; then
        # Prompt user to confirm removal
        echo -n "Backup directory ($BACKUP_DIR) already exists. Remove it? (y/n): "
        read -r REMOVE_BACKUP
        if [[ "$REMOVE_BACKUP" == "y" || "$REMOVE_BACKUP" == "Y" ]]; then
            log "Removing existing backup directory"
            chown -R "$USER:" "$BACKUP_DIR"
            rm -rf "$BACKUP_DIR"
            sleep 1
        else
            log "Skipping local backup creation"
            return 0
        fi
    fi

    # Continue with backup creation if needed
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        
        # Backup database
        log "Backing up local database..."
        db_dump_file="$BACKUP_DIR/database_backup_$(date +%Y%m%d).sql"

        # Create the database backup
        if [ -n "$DB_PASSWORD" ]; then
            PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" pg_dump -d "$DB_NAME" -c --no-owner > "$db_dump_file"
        else
            sudo -u "$DB_SYSTEM_USER" pg_dump -d "$DB_NAME" -c --no-owner > "$db_dump_file"
        fi
        check_error "Failed to create local database backup"
        
        # Backup configuration files
        log "Backing up configuration files..."
        mkdir -p "$BACKUP_DIR/config/payara"
        
        # Check if Payara config directory exists and is readable
        PAYARA_CONFIG_DIR="$PAYARA/glassfish/domains/domain1/config"
        if ! sudo test -d "$PAYARA_CONFIG_DIR"; then
            log "ERROR: Payara config directory does not exist or is not accessible"
            return 1
        fi
        
        # List contents of config directory for debugging
        log "Contents of Payara config directory:"
        sudo ls -la "$PAYARA_CONFIG_DIR"
        
        # Copy Payara configuration files with sudo rsync
        log "Copying Payara configuration files..."
        if ! sudo rsync -av "$PAYARA_CONFIG_DIR/" "$BACKUP_DIR/config/payara/"; then
            log "ERROR: Failed to backup Payara configuration"
            return 1
        fi
        
        # Fix permissions of backed up files
        sudo chown -R "$USER:" "$BACKUP_DIR/config/payara"
        
        # Backup Dataverse config from Payara config directory
        log "Backing up Dataverse configuration from Payara config..."
        mkdir -p "$BACKUP_DIR/config/"
        if ! sudo rsync -av "$PAYARA_CONFIG_DIR" "$BACKUP_DIR/config"; then
            log "ERROR: Failed to backup Dataverse configuration from $PAYARA_CONFIG_DIR"
            log "This is a critical component and the backup cannot proceed without it."
            return 1
        fi
        
        sudo chown -R "$USER:" "$BACKUP_DIR"
        log "Dataverse configuration backed up successfully"
        
        log "Backup completed successfully"
    fi
}

# Function to set database permissions
set_database_permissions() {
    log "Setting database permissions..."
    
    # Grant all privileges on all tables to the database user
    if [ -n "$DB_PASSWORD" ]; then
        PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" << EOF
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "$DB_USER";
EOF
    else
        sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" << EOF
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "$DB_USER";
EOF
    fi
    check_error "Failed to set database permissions"
    
    log "Database permissions set successfully"
    return 0
}

# Function to execute SQL commands (helper for S3 configuration)
execute_sql_on_clone() {
    local sql_commands="$1"
    local psql_output

    log "Executing SQL on clone DB '$DB_NAME': $sql_commands"

    # Ensure DB_USER exists and has necessary privileges before running arbitrary SQL
    # This is typically handled by the main restore process owning objects by DB_SYSTEM_USER
    # and then reassigning to DB_USER. Assuming DB_USER can modify settings table.

    if [ -n "$DB_PASSWORD" ]; then
        export PGPASSWORD="$DB_PASSWORD"
        # Run as DB_USER if possible, or DB_SYSTEM_USER if setting modification requires it.
        # For settings, usually DB_USER (application user) should have rights if schema is well-defined.
        # Sticking to DB_SYSTEM_USER for now for maximum privilege on settings table.
        psql_output=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -v ON_ERROR_STOP=1 --quiet -c "$sql_commands" 2>&1)
        local psql_exit_code=$?
        unset PGPASSWORD
    else
        psql_output=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -v ON_ERROR_STOP=1 --quiet -c "$sql_commands" 2>&1)
        local psql_exit_code=$?
    fi

    if [ $psql_exit_code -ne 0 ]; then
        log_warning "SQL execution failed. Exit code: $psql_exit_code"
        log "Failed SQL Commands: $sql_commands"
        log "psql Output: $psql_output"
        # Do not return 1 here, allow script to continue but log warning.
        # S3 config is important but might not be a fatal error for all script uses.
        return 1
    else
        log "SQL execution for S3 config successful."
        if [[ -n "$psql_output" && "$psql_output" != *"UPDATE 0"* && "$psql_output" != *"DELETE 0"* ]]; then
             log "psql Output: $psql_output"
        fi
        return 0
    fi
}

# Function to detect S3 from the local dump and prompt user for clone configuration
prompt_s3_configuration() {
    log "Detecting S3 configuration from downloaded production database dump ($DB_DUMP_FILE)..."
    local prod_s3_db_setting_found=false
    local pg_restore_output
    local pg_restore_exit_code

    # Ensure DB_DUMP_FILE is set and accessible
    if [ -z "$DB_DUMP_FILE" ] || ! sudo -u "$DB_SYSTEM_USER" test -r "$DB_DUMP_FILE"; then
        log_warning "DB_DUMP_FILE variable is not set or dump file is not readable by $DB_SYSTEM_USER."
        log_warning "Cannot determine S3 DB configuration from dump."
        # Do not default S3_CONFIG_CHOICE here yet
    else
        if (set -o pipefail; sudo -u "$DB_SYSTEM_USER" pg_restore "$DB_DUMP_FILE" -f - 2>/dev/null | grep -q ":S3BucketName"); then
            prod_s3_db_setting_found=true
        else
            log "Did not find ':S3BucketName' in dump's setting table, or pg_restore failed while inspecting dump."
        fi
    fi

    local prod_s3_jvm_setting_found=false
    if [ ${#PROD_S3_OPTIONS[@]} -gt 0 ]; then
        prod_s3_jvm_setting_found=true
    fi

    local prod_effectively_uses_s3=false
    if [ "$prod_s3_db_setting_found" = true ] || [ "$prod_s3_jvm_setting_found" = true ]; then
        prod_effectively_uses_s3=true
    fi

    if [ "$prod_effectively_uses_s3" = true ]; then
        log "Production Dataverse appears to be using S3 storage."
        if [ "$prod_s3_db_setting_found" = true ]; then log "  (S3 DB setting :S3BucketName detected in dump)"; fi
        if [ "$prod_s3_jvm_setting_found" = true ]; then log "  (S3 JVM options detected in production: ${PROD_S3_OPTIONS[*]})"; fi
        
        echo ""
        echo "Production appears to use S3 storage. How should the clone's storage be configured?"
        echo "  1. Configure a specific S3 bucket for the clone (Enter details)."
        echo "  2. Switch clone to local file storage (files in '$DATAVERSE_CONTENT_STORAGE')."
        echo "  3. Attempt to inherit S3 settings from production (NOT RECOMMENDED; may use production bucket or fail)."

        local choice
        while true; do
            echo -n "Enter your choice (1, 2, or 3) [Default: 1 for clone S3]: "
            read -r choice
            if [ -z "$choice" ]; then choice="1"; fi # Default to 1 if prod uses S3

            case "$choice" in
                1|2|3) break;;
                *) echo "Invalid choice. Please enter 1, 2, or 3.";;
            esac
        done
        S3_CONFIG_CHOICE="$choice"
    else
        log "S3 storage not detected in production (neither relevant DB setting in dump nor S3 JVM options)."
        echo ""
        echo "Production does not appear to use S3. How should the clone's storage be configured?"
        echo "  1. Configure a specific S3 bucket for the clone (Enter details)."
        echo "  2. Switch clone to local file storage (Recommended Default) (files in '$DATAVERSE_CONTENT_STORAGE')."
        local choice
        while true; do
            echo -n "Enter your choice (1 or 2) [Default: 2 for local storage]: "
            read -r choice
            if [ -z "$choice" ]; then choice="2"; fi # Default to 2 if prod does not use S3
            case "$choice" in
                1|2) break;;
                *) echo "Invalid choice. Please enter 1 or 2.";;
            esac
        done
        S3_CONFIG_CHOICE="$choice"
    fi

    if [ "$S3_CONFIG_CHOICE" == "1" ]; then
        log "User chose to configure a new S3 bucket for the clone."
        echo "Enter details for the clone's S3 bucket:"
        echo -n "  Bucket Name: "
        read -r INPUT_CLONE_S3_BUCKET_NAME
        # echo -n "  Access Key ID: "
        # read -r INPUT_CLONE_S3_ACCESS_KEY
        # echo -n "  Secret Access Key: "
        # read -s INPUT_CLONE_S3_SECRET_KEY
        echo ""
        echo -n "  Region (e.g., us-east-2, optional - leave blank if not needed): "
        read -r INPUT_CLONE_S3_REGION
        echo -n "  S3 Endpoint URL (optional - e.g., http://minio:9000 - leave blank if using default AWS S3 endpoint): "
        read -r INPUT_CLONE_S3_ENDPOINT_URL
        log "Collected new S3 details for clone: Bucket=$INPUT_CLONE_S3_BUCKET_NAME, Region=$INPUT_CLONE_S3_REGION, Endpoint=$INPUT_CLONE_S3_ENDPOINT_URL"
    elif [ "$S3_CONFIG_CHOICE" == "2" ]; then
        log "User chose to switch clone to local file storage."
    elif [ "$S3_CONFIG_CHOICE" == "3" ]; then
        log "User chose to skip S3 configuration changes."
    fi

    # Call the verification function
    verify_clone_s3_configuration "$S3_CONFIG_CHOICE" "$INPUT_CLONE_S3_BUCKET_NAME"
}

# Function to verify clone S3 configuration against production
verify_clone_s3_configuration() {
    local s3_choice="$1"
    local clone_bucket_name_input="$2" # Only relevant if s3_choice is 1

    log "Verifying clone's S3 configuration post-selection..."

    # Fetch current LOCAL S3 JVM options for verification
    log "Fetching current local JVM options for S3 verification..."
    CURRENT_LOCAL_JVM_OPTIONS=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$CURRENT_LOCAL_JVM_OPTIONS" ]; then
        log_warning "Could not fetch current local JVM options. S3 verification against live JVM settings will be skipped."
        # Do not exit, but subsequent checks on CURRENT_LOCAL_S3_JVM_OPTS will be empty
        CURRENT_LOCAL_S3_JVM_OPTS=()
    else
        # Temporarily populate local S3 options for this check without affecting the global summary variables yet.
        # We use a local variable array for this.
        local current_local_s3_options_temp=()
        local current_local_s3_props_temp=() # Not strictly needed for this check but part of scan_s3_jvm_options structure
        local current_local_s3_duplicates_temp=() # ditto

        # Simplified scan for S3 options based on scan_s3_jvm_options logic
        while IFS= read -r option; do
            [ -z "$option" ] && continue
            [[ ! "$option" =~ ^-D ]] && continue
            [[ "$option" =~ "JDK versions:" ]] && continue
            option=$(echo "$option" | sed -E 's/[[:space:]]*-->.*$//' | sed -E 's/[[:space:]]*$//')
            [ -z "$option" ] && continue
            if [[ "$option" =~ ^-D([^=]+)= ]]; then
                local prop_name="${BASH_REMATCH[1]}"
                if [[ "$prop_name" =~ s3|S3|aws|AWS ]]; then
                    current_local_s3_options_temp+=("$option")
                fi
            fi
        done <<< "$CURRENT_LOCAL_JVM_OPTIONS"
        CURRENT_LOCAL_S3_JVM_OPTS=("${current_local_s3_options_temp[@]}") # Assign to a known variable name for use below
    fi


    if [ "$s3_choice" == "1" ]; then # User chose to configure S3 for the clone
        log "Verification for S3 choice '1': Clone configured to use S3 bucket '$clone_bucket_name_input'."
        local potential_prod_bucket_match=false
        if [ -n "$clone_bucket_name_input" ] && [ ${#PROD_S3_OPTIONS[@]} -gt 0 ]; then
            for prod_s3_opt in "${PROD_S3_OPTIONS[@]}"; do
                # Extract bucket name from prod_s3_opt, e.g., -Ddataverse.s3.bucket-name=PRODBUCKET
                if [[ "$prod_s3_opt" =~ dataverse\.files\.s3\.bucket-name=([^[:space:]]+) ]] || \
                   [[ "$prod_s3_opt" =~ dataverse\.s3\.bucket-name=([^[:space:]]+) ]] || \
                   [[ "$prod_s3_opt" =~ aws\.s3\.bucket=([^[:space:]]+) ]]; then # Add other known patterns
                    local prod_bucket_from_jvm="${BASH_REMATCH[1]}"
                    prod_bucket_from_jvm=$(echo "$prod_bucket_from_jvm" | tr -d '"' ) # Remove potential quotes

                    if [ "$clone_bucket_name_input" == "$prod_bucket_from_jvm" ]; then
                        potential_prod_bucket_match=true
                        log_warning "CRITICAL RISK: The clone's S3 bucket name ('$clone_bucket_name_input') is IDENTICAL to a bucket name found in PRODUCTION S3 JVM options ('$prod_bucket_from_jvm' from option '$prod_s3_opt')."
                        break
                    fi
                fi
            done
        fi

        if [ "$potential_prod_bucket_match" = true ]; then
            echo ""
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "The S3 bucket name you entered for the CLONE ('$clone_bucket_name_input')"
            echo "MATCHES an S3 bucket name found in the PRODUCTION server's JVM options."
            echo "Using a production S3 bucket for a clone can lead to data corruption or loss."
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo -n "Are you ABSOLUTELY SURE you want to proceed with this S3 bucket for the clone? (yes/no): "
            read -r confirm_prod_bucket_use
            if [[ "$confirm_prod_bucket_use" != "yes" ]]; then
                log "User aborted due to S3 bucket name matching production. Exiting."
                exit 1
            else
                log_warning "User CONFIRMED using S3 bucket '$clone_bucket_name_input' despite it matching a production S3 JVM option."
            fi
        fi

        # Check if the chosen clone bucket name is reflected in *current* local JVM options
        local clone_bucket_in_local_jvm=false
        if [ -n "$clone_bucket_name_input" ] && [ ${#CURRENT_LOCAL_S3_JVM_OPTS[@]} -gt 0 ]; then
             for local_s3_opt in "${CURRENT_LOCAL_S3_JVM_OPTS[@]}"; do
                if [[ "$local_s3_opt" =~ $clone_bucket_name_input ]]; then
                    clone_bucket_in_local_jvm=true
                    log "Verification: Intended clone S3 bucket '$clone_bucket_name_input' appears to be present in current local JVM S3 options."
                    break
                fi
            done
        fi
        if [ "$clone_bucket_in_local_jvm" = false ] && [ -n "$clone_bucket_name_input" ]; then
            log_warning "Intended clone S3 bucket '$clone_bucket_name_input' is NOT currently reflected in local S3 JVM options. The 'verify_jvm_options' step should apply this later. If S3 issues persist, ensure JVM options are correctly set."
        fi

    elif [ "$s3_choice" == "2" ]; then # User chose local file storage
        log "Verification for S3 choice '2': Clone configured for local file storage."
        if [ ${#CURRENT_LOCAL_S3_JVM_OPTS[@]} -gt 0 ]; then
            log_warning "Local file storage was chosen, but the following S3-related JVM options are currently active on the clone:"
            for local_s3_opt in "${CURRENT_LOCAL_S3_JVM_OPTS[@]}"; do
                log_warning "  - $local_s3_opt"
            done
            log_warning "These S3 JVM options might conflict with local file storage. The 'verify_jvm_options' step may attempt to remove them if they were also in production. Review JVM options if storage issues occur."
        else
            log "Verification: No S3-related JVM options detected locally, consistent with choosing local file storage."
        fi
    else
        log "Verification: S3 choice is '$s3_choice'. No specific S3 bucket verification needed for this choice."
    fi
    log "Clone S3 configuration verification step completed."
}

# Function to sync database
sync_database() {
    echo ""
    log "=== DATABASE OPERATIONS ==="
    
    log "Creating temporary directory for database dump on production server..."
    # Create the temporary directory as the database system user to ensure proper permissions from the start
    TEMP_DUMP_DIR=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u $PRODUCTION_DB_SYSTEM_USER mktemp -d")
    check_error "Failed to create temporary directory on production server"
    log "Created temporary directory: $TEMP_DUMP_DIR on production server"

    # Create local temporary directory
    LOCAL_TEMP_DIR=$(mktemp -d)
    check_error "Failed to create local temporary directory"
    log "Created local temporary directory: $LOCAL_TEMP_DIR"
    
    # Set proper permissions on temporary directory to allow both current user and postgres to access
    sudo chown "$USER:$DB_SYSTEM_USER" "$LOCAL_TEMP_DIR"
    sudo chmod 775 "$LOCAL_TEMP_DIR"
    
    DB_DUMP_FILE="$LOCAL_TEMP_DIR/${PRODUCTION_DB_NAME}_$(date +%Y%m%d).dump" # Changed extension for Fc format
    log "Using $DB_DUMP_FILE for database dump."
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would fetch database dump from $PRODUCTION_SERVER"
        log "DRY RUN: Would create database dump: $DB_DUMP_FILE"
        log "DRY RUN: Would restore database to $DB_HOST/$DB_NAME"
        log "PRESERVED: Local database credentials"
        return 0
    fi
    
    # Estimate required dump size on production
    log "Estimating required space for database dump on production..."
    PROD_DB_SIZE=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u $PRODUCTION_DB_SYSTEM_USER psql -d '$PRODUCTION_DB_NAME' -t -c \"SELECT pg_database_size('$PRODUCTION_DB_NAME');\" | tr -d '[:space:]'")
    if [[ ! "$PROD_DB_SIZE" =~ ^[0-9]+$ ]]; then
        log "WARNING: Could not estimate database size. Defaulting to 2GB."
        PROD_DB_SIZE=$((2*1024*1024*1024))
    fi
    # Add 20% safety margin
    PROD_DUMP_SIZE_EST=$((PROD_DB_SIZE + PROD_DB_SIZE / 5))
    log "Estimated dump size: $((PROD_DUMP_SIZE_EST / 1024 / 1024)) MB"
    
    # Check space in temporary directory
    AVAIL_SPACE=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "df -B1 '$TEMP_DUMP_DIR' | awk 'NR==2 {print \$4}'")
    if [[ ! "$AVAIL_SPACE" =~ ^[0-9]+$ ]]; then
        log "WARNING: Could not check available space in temporary directory. Proceeding anyway."
    elif [ "$AVAIL_SPACE" -lt "$PROD_DUMP_SIZE_EST" ]; then
        log "ERROR: Not enough space in temporary directory. Available: $((AVAIL_SPACE / 1024 / 1024)) MB, Required: $((PROD_DUMP_SIZE_EST / 1024 / 1024)) MB"
        ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo rm -rf '$TEMP_DUMP_DIR'"
        return 1
    else
        log "Sufficient space available in temporary directory: $((AVAIL_SPACE / 1024 / 1024)) MB (needed: $((PROD_DUMP_SIZE_EST / 1024 / 1024)) MB)"
    fi
    
    # Set the dump file path in the temporary directory
    PROD_DUMP_FILE="$TEMP_DUMP_DIR/${PRODUCTION_DB_NAME}_$(date +%Y%m%d).dump" # Changed extension for Fc format
    log "Using $PROD_DUMP_FILE for database dump."
    
    # Create the database dump
    log "Creating database dump on production server (custom format, no owner, no ACLs)..."
    if [ "$DEBUG" = true ]; then
        ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u \"$PRODUCTION_DB_SYSTEM_USER\" pg_dump -Fc -O -x -d \"$PRODUCTION_DB_NAME\" -f \"$PROD_DUMP_FILE\""
        if [ $? -ne 0 ]; then
            check_error "Failed to create database dump on production"
        fi
    else
        ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u \"$PRODUCTION_DB_SYSTEM_USER\" pg_dump -Fc -O -x -d \"$PRODUCTION_DB_NAME\" -f \"$PROD_DUMP_FILE\"" >/dev/null 2>&1
        check_error "Failed to create database dump on production"
    fi
    
    # Verify the dump file exists and is not empty
    log "Verifying database dump file..."
    FILE_SIZE=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo ls -la '$PROD_DUMP_FILE' | awk '{print \$5}'")
    if [[ ! "$FILE_SIZE" =~ ^[0-9]+$ ]]; then
        log "ERROR: Cannot verify database dump file size. File may not exist."
        ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo ls -la '$TEMP_DUMP_DIR'"
        return 1
    elif [ "$FILE_SIZE" -eq 0 ]; then
        log "ERROR: Database dump file is empty (0 bytes)."
        return 1
    else
        log "Database dump file created successfully: $FILE_SIZE bytes"
    fi
    
    # Change ownership to allow copying
    log "Changing ownership of database dump file for transfer..."
    ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo chown -R '$PRODUCTION_SSH_USER' '$TEMP_DUMP_DIR'"
    check_error "Failed to change ownership of database dump file"
    
    # Verify permissions after ownership change
    log "Verifying file permissions..."
    PERMISSIONS=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo ls -la '$PROD_DUMP_FILE' | awk '{print \$1}'")
    log "Current permissions: $PERMISSIONS"
    
    OWNER=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo ls -la '$PROD_DUMP_FILE' | awk '{print \$3}'")
    log "Current owner: $OWNER"
    
    # Make sure the file is readable
    ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo chmod +r '$PROD_DUMP_FILE'"
    check_error "Failed to make database dump file readable"
    
    # Copy database dump to local server
    log "Copying database dump from production ($(( FILE_SIZE / 1024 / 1024 )) MB)..."
    FILE_INFO=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo file '$PROD_DUMP_FILE'")
    log "File info: $FILE_INFO"
    log "Source file: $PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PROD_DUMP_FILE"
    log "Destination file: $DB_DUMP_FILE"
    
    # Debug directory contents
    ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo ls -la '$TEMP_DUMP_DIR'"
    
    # Verify connectivity before attempting transfer
    verify_ssh_connectivity "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER"
    
    # Try direct rsync with full error output capture
    log "Attempting database transfer with rsync..."
    if rsync -avz --stats --info=progress2 --progress "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PROD_DUMP_FILE" "$DB_DUMP_FILE"; then
        log "Transfer successful with direct rsync."
    else
        RSYNC_EXIT_CODE=$?
        log "RSYNC ERROR (code $RSYNC_EXIT_CODE). Trying alternative transfer method..."
        
        log "Trying alternative transfer method (scp)..."
        if scp "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PROD_DUMP_FILE" "$DB_DUMP_FILE"; then
            log "Transfer successful with scp."
        else
            log "ERROR: All file transfer methods failed. Database dump could not be copied from production."
            return 1
        fi
    fi
    
    # Verify the file was copied correctly
    if [ ! -f "$DB_DUMP_FILE" ]; then
        log "ERROR: Database dump file was not copied to local system."
        return 1
    fi
    
    LOCAL_FILE_SIZE=$(stat -c%s "$DB_DUMP_FILE" 2>/dev/null || echo "0")
    if [ "$LOCAL_FILE_SIZE" -eq 0 ]; then
        log "ERROR: Copied database dump file is empty."
        return 1
    fi
    
    log "Database dump transfer completed. Local file size: $(( LOCAL_FILE_SIZE / 1024 / 1024 )) MB"
    
    # Clean up the temporary directory on production server
    log "Cleaning up temporary directory on production server..."
    ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo rm -rf '$TEMP_DUMP_DIR'"

    # Prompt for S3 configuration based on the downloaded dump BEFORE any destructive local DB changes
    # $DB_DUMP_FILE is now set and contains the production dump data.
    if [ "$DRY_RUN" = false ]; then
        prompt_s3_configuration
    else
        S3_CONFIG_CHOICE="skip" # In dry-run, we won't modify actual settings
        log "DRY RUN: Would prompt for S3 configuration based on downloaded dump."
    fi
    
    # Set proper permissions for the database dump file
    log "Setting permissions for local dump file $DB_DUMP_FILE to be readable by $DB_SYSTEM_USER..."
    sudo chown "$DB_SYSTEM_USER:$DB_SYSTEM_USER" "$DB_DUMP_FILE"
    sudo chmod 600 "$DB_DUMP_FILE" # Ensure $DB_SYSTEM_USER can read
    
    # Verify file permissions
    log "Verifying file permissions..."
    ls -l "$DB_DUMP_FILE"
    
    # Check if the file exists and is readable by DB_SYSTEM_USER
    log "Verifying file accessibility..."
    if ! sudo -u "$DB_SYSTEM_USER" bash -c "test -f '$DB_DUMP_FILE' && test -r '$DB_DUMP_FILE'"; then
        log "ERROR: Database dump file $DB_DUMP_FILE is not accessible by $DB_SYSTEM_USER"
        log "Current permissions:"
        ls -l "$DB_DUMP_FILE"
        log "Current owner:"
        ls -l "$DB_DUMP_FILE" | awk '{print $3}'
        log "Testing file access as $DB_SYSTEM_USER:"
        sudo -u "$DB_SYSTEM_USER" bash -c "ls -l '$DB_DUMP_FILE'"
        return 1
    fi
    
    # Check if database is empty
    log "Checking if database is empty..."
    TABLE_COUNT=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')
    # If psql fails (e.g. DB doesn't exist yet), TABLE_COUNT might be empty. Default to 0.
    if [[ ! "$TABLE_COUNT" =~ ^[0-9]+$ ]]; then
        TABLE_COUNT=0
    fi

    if [ "$TABLE_COUNT" -eq 0 ]; then
        log "Database is empty or does not exist."
        # No need to modify dump file if it's custom format and we're doing full restore.
    else
        log "Database is not empty. It will be dropped and recreated."
    fi
    
    # Modify domain-specific settings in the dump - REMOVED FOR Fc format.
    # log "Updating domain-specific settings in database dump..."
    # sudo -u "$DB_SYSTEM_USER" sed -i "s/$PRODUCTION_DOMAIN/$DOMAIN/g" "$DB_DUMP_FILE" # THIS MUST BE REMOVED FOR Fc

    # Restore database
    log "Dropping local database '$DB_NAME' if it exists..."

    # Ensure DB_USER exists and can create databases
    log "Ensuring database user '$DB_USER' exists and has CREATEDB privilege..."
    CREATE_ROLE_SQL="CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD NULL;"
    GRANT_CREATEDB_SQL="ALTER ROLE \"$DB_USER\" CREATEDB;"
    local psql_create_output psql_alter_output createdb_output

    if [ -n "$DB_PASSWORD" ]; then 
        export PGPASSWORD="$DB_PASSWORD"
        psql_create_output=$(sudo -u "$DB_SYSTEM_USER" psql -d postgres -c "$CREATE_ROLE_SQL" 2>&1)
        if [ $? -ne 0 ] && ! echo "$psql_create_output" | grep -q "already exists"; then
            log "ERROR during CREATE ROLE for $DB_USER: $psql_create_output"
        else
            log "CREATE ROLE for $DB_USER executed (may have already existed). Output: $psql_create_output"
        fi
        psql_alter_output=$(sudo -u "$DB_SYSTEM_USER" psql -d postgres -c "$GRANT_CREATEDB_SQL" 2>&1)
        if [ $? -ne 0 ]; then
            log "ERROR during ALTER ROLE CREATEDB for $DB_USER: $psql_alter_output"
        else
            log "ALTER ROLE CREATEDB for $DB_USER executed. Output: $psql_alter_output"
        fi
        unset PGPASSWORD
    else
        psql_create_output=$(sudo -u "$DB_SYSTEM_USER" psql -d postgres -c "$CREATE_ROLE_SQL" 2>&1)
        if [ $? -ne 0 ] && ! echo "$psql_create_output" | grep -q "already exists"; then
            log "ERROR during CREATE ROLE for $DB_USER: $psql_create_output"
        else
            log "CREATE ROLE for $DB_USER executed (may have already existed). Output: $psql_create_output"
        fi
        psql_alter_output=$(sudo -u "$DB_SYSTEM_USER" psql -d postgres -c "$GRANT_CREATEDB_SQL" 2>&1)
        if [ $? -ne 0 ]; then
            log "ERROR during ALTER ROLE CREATEDB for $DB_USER: $psql_alter_output"
        else
            log "ALTER ROLE CREATEDB for $DB_USER executed. Output: $psql_alter_output"
        fi
    fi
    log "Attempt to ensure user and privileges completed."

    local dropdb_output
    log "Dropping local database '$DB_NAME' if it exists (tolerant to non-existence)..."
    if [ -n "$DB_PASSWORD" ]; then
        dropdb_output=$(PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" dropdb --if-exists "$DB_NAME" 2>&1)
    else
        dropdb_output=$(sudo -u "$DB_SYSTEM_USER" dropdb --if-exists "$DB_NAME" 2>&1)
    fi
    if [ $? -ne 0 ] && ! echo "$dropdb_output" | grep -q "does not exist"; then
        # Error only if it failed for a reason other than not existing
        log "ERROR: dropdb failed for '$DB_NAME'. Output: $dropdb_output"
        exit 1
    else
        log "dropdb command executed for '$DB_NAME'. Output: $dropdb_output"
    fi

    log "Creating new local database '$DB_NAME' owned by '$DB_USER'..."
    if [ -n "$DB_PASSWORD" ]; then
        createdb_output=$(PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" createdb -O "$DB_USER" "$DB_NAME" 2>&1)
    else
        createdb_output=$(sudo -u "$DB_SYSTEM_USER" createdb -O "$DB_USER" "$DB_NAME" 2>&1)
    fi
    if [ $? -ne 0 ]; then
        # If createdb failed, check if it was because the database already exists
        if echo "$createdb_output" | grep -q "already exists"; then
            log "Warning: createdb failed because database '$DB_NAME' already exists. This may be due to an incomplete drop. Proceeding with restore."
            log "createdb output: $createdb_output"
        else
            log "ERROR: Failed to create local database '$DB_NAME' with owner '$DB_USER'. Output: $createdb_output"
            exit 1 # Exit for other critical createdb errors
        fi
    else
        log "Successfully created database '$DB_NAME' owned by '$DB_USER'. Output: $createdb_output"
    fi

    log "Restoring database to local server '$DB_NAME' using pg_restore (no owner, no ACLs) from Production dump file with $number_of_items_to_reindex items to reindex"
    # Set PGPASSWORD for pg_restore
    export PGPASSWORD="$DB_PASSWORD"
    
    # Use a temporary file for pg_restore output if debugging
    local pg_restore_output_file="$(mktemp)"

    if [ "$DEBUG" = true ]; then
        log "DEBUG: Running pg_restore command: sudo -u $DB_SYSTEM_USER pg_restore -d $DB_NAME --no-owner --no-acl --exit-on-error --verbose $DB_DUMP_FILE"
        # Redirect output to temporary file first
        if ! sudo -u "$DB_SYSTEM_USER" pg_restore -d "$DB_NAME" --no-owner --no-acl --exit-on-error --verbose "$DB_DUMP_FILE" > "$pg_restore_output_file" 2>&1; then
            log "ERROR: Database restore failed for $DB_NAME"
            log "--- pg_restore output (from $pg_restore_output_file) ---"
            cat "$pg_restore_output_file" >> "$LOGFILE" # Append captured output to logfile on error
            cat "$pg_restore_output_file" # Also print to terminal
            log "--- End pg_restore output ---"
            rm "$pg_restore_output_file"
            unset PGPASSWORD
            rm -rf "$LOCAL_TEMP_DIR" # Clean up local temp dump dir
            return 1
        else
            # Log successful output in debug mode
            log "DEBUG: pg_restore completed successfully. Output (from $pg_restore_output_file):"
            cat "$pg_restore_output_file" >> "$LOGFILE" # Append captured output to logfile on success too
            cat "$pg_restore_output_file" # Also print to terminal
            log "--- End pg_restore output ---"
        fi
    else
        # Original non-debug behavior
        if ! sudo -u "$DB_SYSTEM_USER" pg_restore -d "$DB_NAME" --no-owner --no-acl --exit-on-error --verbose "$DB_DUMP_FILE" >/dev/null 2>&1; then
            log "ERROR: Database restore failed for $DB_NAME"
            unset PGPASSWORD
            rm -rf "$LOCAL_TEMP_DIR" # Clean up local temp dump dir
            return 1
        fi
    fi
    
    # Clean up temporary output file if created
    if [ -f "$pg_restore_output_file" ]; then
      rm "$pg_restore_output_file"
    fi

    unset PGPASSWORD
    log "Database restore completed for $DB_NAME"

    # The block for changing ownership of restored objects is removed as REASSIGN OWNED BY cannot affect
    # objects owned by the 'postgres' superuser that are required by the database system, and
    # the subsequent set_database_permissions function grants necessary privileges to the application user.

    # log "Changing ownership of restored objects to $DB_USER..."
    # # Reassign ownership only for objects within the public schema
    # REASSIGN_SQL="REASSIGN OWNED BY \"$DB_SYSTEM_USER\" TO \"$DB_USER\" IN SCHEMA public;"
    # # GRANT_SQL is not needed here as set_database_permissions handles it more comprehensively later.
    # # GRANT_SQL="GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$DB_USER\"; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$DB_USER\"; GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO \"$DB_USER\";"
    
    # if [ -n "$DB_PASSWORD" ]; then
    #     export PGPASSWORD="$DB_PASSWORD"
    #     # Run REASSIGN as DB_SYSTEM_USER, as this user owns the objects after restore
    #     if [ "$DEBUG" = true ]; then
    #         log "DEBUG: Running psql command: sudo -u $DB_SYSTEM_USER psql -d $DB_NAME -c \"$REASSIGN_SQL\""
    #         # Capture output even on success in debug mode
    #         if ! psql_reassign_output=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -c "$REASSIGN_SQL" 2>&1); then
    // ... existing code ...

    # Run post-restore SQL to update settings for non-production instance
    log "Running post-restore SQL to update settings for non-production instance..."
    STANDARD_POST_RESTORE_SQL="
        UPDATE setting SET content = 'false' WHERE name = ':AllowD 게시판Register'; -- Example, assuming this key for DOI
        UPDATE setting SET content = 'THIS IS A CLONE/TEST INSTANCE - NOT PRODUCTION' WHERE name = 'SiteNotice';
        INSERT INTO setting (name, content)
            SELECT 'SiteNotice', 'THIS IS A CLONE/TEST INSTANCE - NOT PRODUCTION'
            WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = 'SiteNotice');
        UPDATE setting SET content = 'false' WHERE name = ':SystemEmail'; -- Example, general system email
        UPDATE setting SET content = 'false' WHERE name = 'dataverse.settings. Απόστολος.send-contact-to-dataverse-org';
        UPDATE setting SET content = 'false' WHERE name = ':SendFeedbackToSystemEmail';
        DELETE from setting WHERE name = ':HostHeader'; -- Important for Shibboleth redirects

        -- Disable various external services that might be enabled in prod
        UPDATE setting SET content = 'false' WHERE name = ':GlobusAppKey';
        UPDATE setting SET content = 'false' WHERE name = ':ZipDownloadLimitProvider';
        UPDATE setting SET content = 'false' WHERE name = ':DataCiteMDSClient.enabled'; -- if using DataCite
        UPDATE setting SET content = 'false' WHERE name = ':DOIEZIdRegistrationProvider.enabled'; -- if using EZID
    "
    # Replacing specific DOI provider keys with a more general approach if possible
    # For example, finding the active DOI provider and disabling it.
    # This is complex, so for now, specific known keys are used.
    # If using a specific DoiProvider name like in the original script:
    # UPDATE setting SET content = 'false' WHERE name = 'DoiProvider.isActive'; # This was in the original

    if [ "$DEBUG" = true ]; then
        log "DEBUG: Running psql command for post-restore SQL: sudo -u $DB_SYSTEM_USER psql -d $DB_NAME -v ON_ERROR_STOP=1 -c \"...\""
        if ! sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "$STANDARD_POST_RESTORE_SQL"; then
             log "ERROR: Failed to run standard post-restore SQL"
             check_error "Failed to run standard post-restore SQL"
        fi
    else
        if ! sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "$STANDARD_POST_RESTORE_SQL" >/dev/null 2>&1; then
            log "ERROR: Failed to run standard post-restore SQL"
            check_error "Failed to run standard post-restore SQL"
        fi
    fi

    log "Applying S3 storage configuration changes for clone..."
    if [ "$S3_CONFIG_CHOICE" == "1" ]; then # New S3
        log "Configuring clone to use a new S3 bucket: $INPUT_CLONE_S3_BUCKET_NAME"
        S3_SETTINGS_SQL="
            UPDATE setting SET content = '$INPUT_CLONE_S3_BUCKET_NAME' WHERE name = ':S3BucketName';
            -- UPDATE setting SET content = '$INPUT_CLONE_S3_ACCESS_KEY' WHERE name = ':S3AccessKey';
            -- UPDATE setting SET content = '$INPUT_CLONE_S3_SECRET_KEY' WHERE name = ':S3SecretKey';
        "
        if [ -n "$INPUT_CLONE_S3_REGION" ]; then
            S3_SETTINGS_SQL="$S3_SETTINGS_SQL UPDATE setting SET content = '$INPUT_CLONE_S3_REGION' WHERE name = ':S3Region';"
        else
            S3_SETTINGS_SQL="$S3_SETTINGS_SQL DELETE FROM setting WHERE name = ':S3Region';" # Remove if blank
        fi
        if [ -n "$INPUT_CLONE_S3_ENDPOINT_URL" ]; then
            S3_SETTINGS_SQL="$S3_SETTINGS_SQL UPDATE setting SET content = '$INPUT_CLONE_S3_ENDPOINT_URL' WHERE name = ':S3EndpointUrl';"
        else
            S3_SETTINGS_SQL="$S3_SETTINGS_SQL DELETE FROM setting WHERE name = ':S3EndpointUrl';" # Remove if blank
        fi
        S3_SETTINGS_SQL="$S3_SETTINGS_SQL UPDATE setting SET content = 's3' WHERE name = ':DefaultStorageDriverId';"
        # Ensure S3 related settings are present or add them
        S3_SETTINGS_SQL="$S3_SETTINGS_SQL
            UPDATE setting SET content = '$INPUT_CLONE_S3_BUCKET_NAME' WHERE name = ':S3BucketName';
            INSERT INTO setting (name, content) SELECT ':S3BucketName', '$INPUT_CLONE_S3_BUCKET_NAME' WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':S3BucketName');

            UPDATE setting SET content = 's3' WHERE name = ':DefaultStorageDriverId';
            INSERT INTO setting (name, content) SELECT ':DefaultStorageDriverId', 's3' WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':DefaultStorageDriverId');
        "
        if [ -n "$INPUT_CLONE_S3_REGION" ]; then
             S3_SETTINGS_SQL="$S3_SETTINGS_SQL
                UPDATE setting SET content = '$INPUT_CLONE_S3_REGION' WHERE name = ':S3Region';
                INSERT INTO setting (name, content) SELECT ':S3Region', '$INPUT_CLONE_S3_REGION' WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':S3Region');"
        fi
        if [ -n "$INPUT_CLONE_S3_ENDPOINT_URL" ]; then
            S3_SETTINGS_SQL="$S3_SETTINGS_SQL
                UPDATE setting SET content = '$INPUT_CLONE_S3_ENDPOINT_URL' WHERE name = ':S3EndpointUrl';
                INSERT INTO setting (name, content) SELECT ':S3EndpointUrl', '$INPUT_CLONE_S3_ENDPOINT_URL' WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':S3EndpointUrl');"
        fi

        execute_sql_on_clone "$S3_SETTINGS_SQL"

    elif [ "$S3_CONFIG_CHOICE" == "2" ]; then # Local File Storage
        log "Configuring clone to use local file storage in '$DATAVERSE_CONTENT_STORAGE'."
        LOCAL_STORAGE_SQL="
            DELETE FROM setting WHERE name = ':S3BucketName';
            DELETE FROM setting WHERE name = ':S3AccessKey';
            DELETE FROM setting WHERE name = ':S3SecretKey';
            DELETE FROM setting WHERE name = ':S3Region';
            DELETE FROM setting WHERE name = ':S3EndpointUrl';
            -- Add other S3 specific settings to delete if known e.g. :S3PathStyleAccess etc.
            DELETE FROM setting WHERE name LIKE '%S3DataverseStorageDriver%'; -- Attempt to catch namespaced S3 settings

            -- Ensure local filesystem directory setting exists and points to DATAVERSE_CONTENT_STORAGE
            UPDATE setting SET content = '$DATAVERSE_CONTENT_STORAGE' WHERE name = ':FileSystemStorageDirectory';
            INSERT INTO setting (name, content)
                SELECT ':FileSystemStorageDirectory', '$DATAVERSE_CONTENT_STORAGE'
                WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':FileSystemStorageDirectory');
            
            -- Ensure DefaultStorageDriverId is 'file'
            UPDATE setting SET content = 'file' WHERE name = ':DefaultStorageDriverId';
             INSERT INTO setting (name, content) SELECT ':DefaultStorageDriverId', 'file'
                WHERE NOT EXISTS (SELECT 1 FROM setting WHERE name = ':DefaultStorageDriverId');
        "
        execute_sql_on_clone "$LOCAL_STORAGE_SQL"

    elif [ "$S3_CONFIG_CHOICE" == "3" ]; then # Skip
        log "Skipping S3 configuration changes for the clone as per user choice."
    else # Default or PROD_USES_S3 was false or an unexpected S3_CONFIG_CHOICE value
        log "No specific S3 configuration changes needed or an invalid S3_CONFIG_CHOICE ('$S3_CONFIG_CHOICE') was encountered."
    fi

    # Set database permissions (already part of original script)
    set_database_permissions
    
    # Clean up local temporary directory
    log "Cleaning up local temporary directory..."
    rm -rf "$LOCAL_TEMP_DIR"
    
    log "Database operations completed"
    return 0
}

# Function to sync files
sync_files() {
    echo ""
    log "=== DATAVERSE FILES ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would sync files from $PRODUCTION_DATAVERSE_CONTENT_STORAGE to $DATAVERSE_CONTENT_STORAGE"
        return 0
    fi
    
    # Create temporary directory for file operations
    TEMP_DIR=$(mktemp -d)
    
    # Sync files with size limit if FULL_COPY is false
    if [ "$FULL_COPY" = "false" ]; then
        log "Performing limited file sync (max 2MB per file)..."
        # First sync to a temporary directory owned by the current user
        TEMP_SYNC_DIR=$(mktemp -d)
        log "Created temporary sync directory: $TEMP_SYNC_DIR"
        
        # Sync to temporary directory first
        rsync -avz --max-size=2m --exclude="*.tmp" --exclude="*.temp" \
            "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PRODUCTION_DATAVERSE_CONTENT_STORAGE/" \
            "$TEMP_SYNC_DIR/"
        check_error "Failed to sync files to temporary directory"
        
        # Then move files to final location with proper ownership
        sudo rsync -avz --exclude="*.tmp" --exclude="*.temp" \
            "$TEMP_SYNC_DIR/" \
            "$DATAVERSE_CONTENT_STORAGE/"
        check_error "Failed to move files to final location"
        
        # Set proper ownership
        sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$DATAVERSE_CONTENT_STORAGE"
        check_error "Failed to set proper ownership"
        
        # Clean up temporary directory
        rm -rf "$TEMP_SYNC_DIR"
    else
        log "Performing full file sync..."
        # First sync to a temporary directory owned by the current user
        TEMP_SYNC_DIR=$(mktemp -d)
        log "Created temporary sync directory: $TEMP_SYNC_DIR"
        
        # Sync to temporary directory first
        rsync -avz --exclude="*.tmp" --exclude="*.temp" \
            "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PRODUCTION_DATAVERSE_CONTENT_STORAGE/" \
            "$TEMP_SYNC_DIR/"
        check_error "Failed to sync files to temporary directory"
        
        # Then move files to final location with proper ownership
        sudo rsync -avz --exclude="*.tmp" --exclude="*.temp" \
            "$TEMP_SYNC_DIR/" \
            "$DATAVERSE_CONTENT_STORAGE/"
        check_error "Failed to move files to final location"
        
        # Set proper ownership
        sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$DATAVERSE_CONTENT_STORAGE"
        check_error "Failed to set proper ownership"
        
        # Clean up temporary directory
        rm -rf "$TEMP_SYNC_DIR"
    fi
    check_error "Failed to sync Dataverse files"
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
    
    log "File sync completed"
    return 0
}

# Function to sync Solr
sync_solr() {
    echo ""
    log "=== SOLR CONFIGURATION ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would sync Solr configuration from $PRODUCTION_SOLR_PATH to $SOLR_PATH"
        return 0
    fi
    
    # Create temporary directory for Solr operations
    TEMP_DIR=$(mktemp -d)
    
    # First sync to temporary directory
    log "Syncing Solr configuration to temporary directory..."
    if ! rsync -avz --exclude="data" --exclude="logs" \
        "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PRODUCTION_SOLR_PATH/" \
        "$TEMP_DIR/"; then
        log "ERROR: Failed to sync Solr configuration to temporary directory"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Then move files to final location with sudo
    log "Moving Solr configuration to final location..."
    if ! sudo rsync -avz --exclude="data" --exclude="logs" \
        "$TEMP_DIR/" \
        "$SOLR_PATH/"; then
        log "ERROR: Failed to move Solr configuration to final location"
        sudo chown -R "$SOLR_USER:$SOLR_USER" "$SOLR_PATH"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Set proper ownership of Solr files
    log "Setting proper ownership of Solr files..."
    if ! sudo chown -R "$SOLR_USER:$SOLR_USER" "$SOLR_PATH"; then
        log "ERROR: Failed to set ownership of Solr files"
        rm -rf "$TEMP_DIR"
        sudo chown -R "$SOLR_USER:$SOLR_USER" "$SOLR_PATH"
        return 1
    fi
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
    
    log "Solr sync completed"
    return 0
}

# Function to sync counter processor
sync_counter_processor() {
    echo ""
    log "=== COUNTER PROCESSOR ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would sync counter processor from $PRODUCTION_COUNTER_PROCESSOR_DIR to $COUNTER_PROCESSOR_DIR"
        return 0
    fi
    
    # Create temporary directory for counter processor operations
    TEMP_DIR=$(mktemp -d)
    
    # First sync to temporary directory
    log "Syncing counter processor to temporary directory..."
    if ! rsync -avz --exclude="*.tmp" --exclude="*.temp" \
        "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER:$PRODUCTION_COUNTER_PROCESSOR_DIR/" \
        "$TEMP_DIR/"; then
        log "ERROR: Failed to sync counter processor to temporary directory"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Then move files to final location with sudo
    log "Moving counter processor to final location..."
    if ! sudo rsync -avz --exclude="*.tmp" --exclude="*.temp" \
        "$TEMP_DIR/" \
        "$COUNTER_PROCESSOR_DIR/"; then
        log "ERROR: Failed to move counter processor to final location"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Set proper ownership of counter processor files
    log "Setting proper ownership of counter processor files..."
    if ! sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$COUNTER_PROCESSOR_DIR"; then
        log "ERROR: Failed to set ownership of counter processor files"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
    
    log "Counter processor sync completed"
    return 0
}

# Function to restart Payara and wait for it to be ready
restart_and_wait_for_payara() {
    log "Restarting Payara and waiting for Dataverse to deploy..."
    if ! sudo systemctl restart payara; then
        log "ERROR: Failed to restart Payara."
        return 1
    fi
    
    # Wait for the application to be ready
    local max_wait=300 # 5 minutes
    local interval=10
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        if curl -s -k http://localhost:8080/api/v1/info/server | grep -q '"status":"OK"'; then
            log "Payara is up and Dataverse is responding."
            return 0
        fi
        log "Waiting for Payara/Dataverse to become available... ($((elapsed/interval))/$(($max_wait/interval)))"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log "ERROR: Timed out waiting for Payara/Dataverse to start."
    return 1
}

# Function to start Payara service
start_payara() {
    log "Starting Payara service..."
    if ! sudo systemctl start payara; then
        log "ERROR: Failed to start Payara service."
        return 1
    fi

    log "Waiting for Payara to initialize..."
    sleep 20 # Give it a moment to start up before proceeding
    return 0
}

# Function to sync external tools
sync_external_tools() {
    echo ""
    log "=== EXTERNAL TOOLS ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would sync external tools configuration from production"
        return 0
    fi
    
    # Get list of external tools from production
    log "Fetching external tools configuration from production..."
    TOOLS=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "curl -s http://localhost:8080/api/admin/externalTools")
    check_error "Failed to fetch external tools from production"
    
    # Transfer each tool configuration
    log "Transferring external tools configuration..."
    echo "$TOOLS" | jq -r '.data[]' | while read -r tool; do
        if ! curl -X POST -H 'Content-type: application/json' \
             http://localhost:8080/api/admin/externalTools \
             -d "$tool"; then
            log "Warning: Failed to transfer tool configuration: $tool"
        fi
    done
    
    log "External tools sync completed"
    return 0
}

# Function to scan for duplicate JVM options
scan_duplicate_jvm_options() {
    local options="$1"
    local duplicates=()
    local seen=()
    
    while IFS= read -r option; do
        # Skip empty lines
        [ -z "$option" ] && continue
        
        # Skip lines that don't start with a dash
        [[ ! "$option" =~ ^- ]] && continue
        
        # Skip lines with JDK version comments
        [[ "$option" =~ "JDK versions:" ]] && continue
        
        # Clean up the option
        option=$(echo "$option" | sed -E 's/[[:space:]]*-->.*$//' | sed -E 's/[[:space:]]*$//')
        
        # Skip if option is empty after cleanup
        [ -z "$option" ] && continue
        
        # Extract property name for -D options
        if [[ "$option" =~ ^-D([^=]+)= ]]; then
            local prop_name="${BASH_REMATCH[1]}"
            if [[ " ${seen[@]} " =~ " ${prop_name} " ]]; then
                duplicates+=("$option")
            else
                seen+=("$prop_name")
            fi
        else
            # For non-property options, check exact match
            if [[ " ${seen[@]} " =~ " ${option} " ]]; then
                duplicates+=("$option")
            else
                seen+=("$option")
            fi
        fi
    done <<< "$options"
    
    if [ ${#duplicates[@]} -gt 0 ]; then
        log "Found ${#duplicates[@]} duplicate JVM options:"
        printf '%s\n' "${duplicates[@]}" | while read -r dup; do
            log "  - $dup"
        done
        return 1
    fi
    return 0
}

# Function to scan for S3-related JVM options
scan_s3_jvm_options() {
    local options="$1"
    local s3_options=()
    local s3_props=()
    local duplicates=()
    local is_prod="$2"  # true for production, false for local
    
    while IFS= read -r option; do
        # Skip empty lines
        [ -z "$option" ] && continue
        
        # Skip lines that don't start with a dash
        [[ ! "$option" =~ ^-D ]] && continue
        
        # Skip lines with JDK version comments
        [[ "$option" =~ "JDK versions:" ]] && continue
        
        # Clean up the option
        option=$(echo "$option" | sed -E 's/[[:space:]]*-->.*$//' | sed -E 's/[[:space:]]*$//')
        
        # Skip if option is empty after cleanup
        [ -z "$option" ] && continue
        
        # Check for S3-related properties
        if [[ "$option" =~ ^-D([^=]+)= ]]; then
            local prop_name="${BASH_REMATCH[1]}"
            if [[ "$prop_name" =~ s3|S3|aws|AWS ]]; then
                s3_options+=("$option")
                s3_props+=("$prop_name")
            fi
        fi
    done <<< "$options"
    
    if [ ${#s3_options[@]} -gt 0 ]; then
        log "Found ${#s3_options[@]} S3-related JVM options:"
        for i in "${!s3_options[@]}"; do
            log "  - ${s3_options[$i]}"
        done
        
        # Check for duplicates in S3 properties
        for prop in "${s3_props[@]}"; do
            count=$(grep -c -- "-D${prop}=" <<< "${s3_options[*]}")
            if [ "$count" -gt 1 ]; then
                duplicates+=("$prop")
            fi
        done
        
        if [ ${#duplicates[@]} -gt 0 ]; then
            log_warning "Found duplicate S3-related properties:"
            for dup in "${duplicates[@]}"; do
                log "  - $dup"
                # Show all values for this property
                grep -- "-D${dup}=" <<< "${s3_options[*]}" | while read -r value; do
                    log "    * $value"
                done
            done
        fi

        # Store results in global variables
        if [ "$is_prod" = true ]; then
            PROD_S3_OPTIONS=("${s3_options[@]}")
            PROD_S3_DUPLICATES=("${duplicates[@]}")
        else
            LOCAL_S3_OPTIONS=("${s3_options[@]}")
            LOCAL_S3_DUPLICATES=("${duplicates[@]}")
        fi
        return 1
    fi
    return 0
}

# Function to verify and sync JVM options
verify_jvm_options() {
    echo ""
    log "=== JVM OPTIONS ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would verify and sync JVM options from production"
        return 0
    fi
    
    # Get production JVM options
    log "Fetching JVM options from production..."
    PROD_OPTIONS=$(ssh "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER" "sudo -u $PRODUCTION_DATAVERSE_USER $PAYARA/bin/asadmin list-jvm-options")
    check_error "Failed to fetch JVM options from production"
    
    # Scan for S3-related options in production (populates PROD_S3_OPTIONS, PROD_S3_DUPLICATES)
    log "Scanning production JVM options for S3-related configurations..."
    scan_s3_jvm_options "$PROD_OPTIONS" true # true for production
    
    # Scan for duplicates in all production options
    log "Scanning production JVM options for duplicates (all types)..."
    if ! scan_duplicate_jvm_options "$PROD_OPTIONS"; then # This function logs if duplicates are found
        log_warning "Found duplicate JVM options in production configuration (see details above)."
    fi
    
    # Get local JVM options
    log "Fetching local JVM options..."
    LOCAL_OPTIONS=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    check_error "Failed to get local JVM options"
    
    # Scan for S3-related options in local configuration (populates LOCAL_S3_OPTIONS, LOCAL_S3_DUPLICATES)
    log "Scanning local JVM options for S3-related configurations..."
    scan_s3_jvm_options "$LOCAL_OPTIONS" false # false for local
    
    # Scan for duplicates in all local options
    log "Scanning local JVM options for duplicates (all types)..."
    if ! scan_duplicate_jvm_options "$LOCAL_OPTIONS"; then # This function logs if duplicates are found
        log_warning "Found duplicate JVM options in local configuration (see details above)."
    fi

    # --- MODIFIED S3 JVM OPTION HANDLING ---
    if [ "$S3_CONFIG_CHOICE" == "2" ]; then # Clone is being configured for local file storage
        if [ ${#LOCAL_S3_OPTIONS[@]} -gt 0 ]; then
            log_warning "Clone is configured for LOCAL FILE STORAGE, but the following S3-related JVM options currently exist on the clone:"
            for local_s3_opt in "${LOCAL_S3_OPTIONS[@]}"; do
                log_warning "  - $local_s3_opt"
            done
            echo ""
            echo "The clone is being configured for LOCAL FILE STORAGE, but S3-related JVM options were found locally (listed above)."
            echo -n "Would you like to REMOVE these existing S3-related JVM options from the LOCAL Payara configuration? (yes/no): "
            read -r REMOVE_LOCAL_S3_FOR_FILE_STORAGE_CHOICE
            echo ""
            if [[ "$REMOVE_LOCAL_S3_FOR_FILE_STORAGE_CHOICE" == "yes" || "$REMOVE_LOCAL_S3_FOR_FILE_STORAGE_CHOICE" == "Y" ]]; then
                log "User chose to remove existing local S3 JVM options."
                local s3_options_removed_count=0
                for s3_opt_to_remove in "${LOCAL_S3_OPTIONS[@]}"; do
                    log "Attempting to remove JVM option from local: '$s3_opt_to_remove'"
                    ASADMIN_DELETE_OUTPUT=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" delete-jvm-options "$s3_opt_to_remove" 2>&1)
                    ASADMIN_DELETE_EXIT_CODE=$?
                    if [ $ASADMIN_DELETE_EXIT_CODE -ne 0 ]; then
                        if echo "$ASADMIN_DELETE_OUTPUT" | grep -q -e "not found" -e "does not exist"; then
                             log "JVM option '$s3_opt_to_remove' already removed or was not present."
                        else
                             log_warning "Failed to remove JVM option '$s3_opt_to_remove' from local. Exit: $ASADMIN_DELETE_EXIT_CODE. Output: $ASADMIN_DELETE_OUTPUT"
                        fi
                    else
                        log "Successfully removed JVM option '$s3_opt_to_remove' from local."
                        s3_options_removed_count=$((s3_options_removed_count + 1))
                    fi
                done

                if [ "$s3_options_removed_count" -gt 0 ]; then
                    log "Refreshing local JVM options after S3 option removal..."
                    LOCAL_OPTIONS=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
                    check_error "Failed to refresh local JVM options after S3 removal"
                    # Rescan local S3 options for summary as it has changed.
                    log "Rescanning local JVM options for S3 configurations for summary update (after removal for local storage)..."
                    scan_s3_jvm_options "$LOCAL_OPTIONS" false # Update LOCAL_S3_OPTIONS global for summary
                fi
            else
                log "User chose NOT to remove existing local S3-related JVM options, despite selecting local file storage for the clone."
            fi
        else
            log "Clone configured for local file storage, and no pre-existing S3-related JVM options found locally. No S3 JVM options to remove."
        fi
    # No specific removal action for S3_CONFIG_CHOICE 1 or 3 here;
    # those cases rely on NOT adding prod S3 options and preserving local ones.
    elif [ "$S3_CONFIG_CHOICE" == "1" ] || [ "$S3_CONFIG_CHOICE" == "3" ]; then
         if [ ${#LOCAL_S3_OPTIONS[@]} -gt 0 ]; then
            log "Clone is configured to use S3 (or inherit). Existing local S3 JVM options will be preserved."
            log "Production S3-specific options (e.g. bucket names, keys defined in JVM) will be SKIPPED."
        else
            log "Clone is configured to use S3 (or inherit), and no specific S3 JVM options were found locally. Ensure S3 is configured correctly via database settings."
        fi
    fi
    # --- END MODIFIED S3 JVM OPTION HANDLING ---
    
    # Add missing options from production, carefully handling S3 type
    log "Synchronizing (adding missing) non-S3 JVM options from production to local..."
    log "S3-specific JVM options from production (e.g. bucket names, keys in JVM) will be SKIPPED."

    local jvm_options_changed_by_add=false
    while IFS= read -r option_from_prod_line; do
        # Skip empty lines from PROD_OPTIONS output
        [ -z "$option_from_prod_line" ] && continue
        # Skip lines that don't start with a dash (e.g. comments or info lines from asadmin output)
        [[ ! "$option_from_prod_line" =~ ^- ]] && continue
        # Skip lines with JDK version comments explicitly (already handled by previous check, but for safety)
        # This targets a common header in 'asadmin list-jvm-options' output
        [[ "$option_from_prod_line" =~ "JDK versions:" ]] && continue

        # Clean up the option (remove any trailing comments like "--> From dataverse..." or whitespace)
        original_option_from_prod_for_log="$option_from_prod_line" # For logging
        option_cleaned_for_check=$(echo "$option_from_prod_line" | sed -E 's/[[:space:]]*-->.*$//' | sed -E 's/[[:space:]]*$//')

        # Skip if option is empty after cleanup (e.g. it was only a comment)
        if [ -z "$option_cleaned_for_check" ]; then
            log "Skipping empty or comment-only option from production (original: '$original_option_from_prod_for_log')"
            continue
        fi
        
        # Determine if this cleaned production option is an S3-related one.
        # PROD_S3_OPTIONS contains full "-Dkey=value" strings for S3 options found in production.
        is_s3_option_from_prod=false
        for prod_s3_opt_value in "${PROD_S3_OPTIONS[@]}"; do
            # Exact match for the cleaned option against known S3 options from production
            if [ "$option_cleaned_for_check" == "$prod_s3_opt_value" ]; then
                is_s3_option_from_prod=true
                break
            fi
        done

        if [ "$is_s3_option_from_prod" = true ]; then
            log "Skipping addition of S3-related JVM option from production: '$option_cleaned_for_check'. Clone's S3 config primarily via DB or existing specific JVM options."
            continue # Skip to the next production option; do not add this S3 option from prod.
        fi

        # If we reach here, option_cleaned_for_check is NOT an S3-specific option from production.
        # Proceed with existing logic to add it if it's missing locally.
        log "Processing non-S3 option from production: '$option_cleaned_for_check'"
        local option_for_asadmin # This will be the final form passed to asadmin create-jvm-options
        local jvm_option_for_comparison # This is the form used to check against LOCAL_OPTIONS output

        # Handle URL-related options by quoting the value for asadmin, if it's a -Dkey=value type
        if [[ "$option_cleaned_for_check" =~ ^-D([^=]+)=(.*https?://.*)$ ]]; then
            local prop_name="${BASH_REMATCH[1]}"
            local url_value="${BASH_REMATCH[2]}"
            # For asadmin, quote the value part: -Dname='value'
            option_for_asadmin="-D${prop_name}='${url_value}'"
            # For comparison against list-jvm-options output, use the unquoted form
            jvm_option_for_comparison="-D${prop_name}=${url_value}"
        else
            option_for_asadmin="$option_cleaned_for_check"
            jvm_option_for_comparison="$option_cleaned_for_check"
        fi
        
        # Check if this non-S3 option (or its property name for -D options) already exists locally.
        # LOCAL_OPTIONS is the raw string output of the local `asadmin list-jvm-options`.
        if [[ "$jvm_option_for_comparison" =~ ^-D([^=]+)= ]]; then
            # It's a -Dproperty=value option. Check if a property with the same NAME exists.
            # This prevents adding -Dfoo=bar_prod if -Dfoo=baz_local already exists.
            prop_name_to_check_locally="${BASH_REMATCH[1]}"
            if ! echo "$LOCAL_OPTIONS" | grep -q -- "-D${prop_name_to_check_locally}="; then
                log "Attempting to add non-S3 JVM option (property name '${prop_name_to_check_locally}' not found locally): '$option_for_asadmin'"
                ASADMIN_OUTPUT_ERR=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$option_for_asadmin" 2>&1)
                ASADMIN_EXIT_CODE=$?
                if [ $ASADMIN_EXIT_CODE -ne 0 ]; then
                    log_warning "Failed to add JVM option '$option_for_asadmin'. Exit: $ASADMIN_EXIT_CODE. Output: $ASADMIN_OUTPUT_ERR"
                else
                    log "Successfully added JVM option: '$option_for_asadmin'"
                    jvm_options_changed_by_add=true
                fi
            else
                log "Non-S3 JVM option with property name '${prop_name_to_check_locally}' already exists locally. Original prod option: '$option_cleaned_for_check'. Skipping addition."
            fi
        else
            # Not a -Dproperty=value option (e.g., -Xmx, -server). Check for an exact match of the option.
            if ! echo "$LOCAL_OPTIONS" | grep -Fq -- "$jvm_option_for_comparison"; then
                log "Attempting to add non-S3 JVM option (exact match for '$jvm_option_for_comparison' not found locally): '$option_for_asadmin'"
                ASADMIN_OUTPUT_ERR=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$option_for_asadmin" 2>&1)
                ASADMIN_EXIT_CODE=$?
                if [ $ASADMIN_EXIT_CODE -ne 0 ]; then
                    log_warning "Failed to add JVM option '$option_for_asadmin'. Exit: $ASADMIN_EXIT_CODE. Output: $ASADMIN_OUTPUT_ERR"
                else
                    log "Successfully added JVM option: '$option_for_asadmin'"
                    jvm_options_changed_by_add=true
                fi
            else
                log "Non-S3 JVM option '$jvm_option_for_comparison' already exists locally. Skipping addition."
            fi
        fi
    done <<< "$PROD_OPTIONS" # End of loop through production options
    
    if [ "$jvm_options_changed_by_add" = true ]; then
        log "Refreshing local JVM options after potential additions..."
        LOCAL_OPTIONS=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
        check_error "Failed to refresh local JVM options after additions"
        # Rescan local S3 options for the summary as it *might* have changed if any non-S3 options were misidentified by scan_s3_jvm_options
        # This is mostly for keeping the summary accurate.
        log "Rescanning local JVM options for S3 configurations for summary update (after potential non-S3 additions)..."
        scan_s3_jvm_options "$LOCAL_OPTIONS" false
    fi

    log "JVM options sync completed."
    STATUS_JVM_OPTIONS="SUCCESS"
}

# Function to explicitly configure JVM options for local file storage
configure_local_storage_jvm_options() {
    log "Configuring essential JVM options for local file storage (delete-then-create)..."
    local file_dir_option="-Ddataverse.files.file.directory=${DATAVERSE_CONTENT_STORAGE}"
    local file_type_option="-Ddataverse.files.file.type=file"
    local file_label_option="-Ddataverse.files.file.label=file"
    local legacy_dir_option="-Ddataverse.files.directory=${DATAVERSE_CONTENT_STORAGE}"
    local upload_redirect_option="-Ddataverse.files.file.upload-redirect=false"
    local download_redirect_option="-Ddataverse.files.file.download-redirect=false"
    local asadmin_cmd="sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin"

    # --- DELETE AND RE-CREATE to ensure correctness ---
    log "Deleting potentially stale local storage JVM options..."
    # This is safe; delete-jvm-options does not error if the option doesn't exist.
    $asadmin_cmd delete-jvm-options "${file_dir_option}"
    $asadmin_cmd delete-jvm-options "${file_type_option}"
    $asadmin_cmd delete-jvm-options "${file_label_option}"
    $asadmin_cmd delete-jvm-options "${legacy_dir_option}"
    $asadmin_cmd delete-jvm-options "${upload_redirect_option}"
    $asadmin_cmd delete-jvm-options "${download_redirect_option}"

    log "Creating definitive local storage JVM options..."
    if ! $asadmin_cmd create-jvm-options "${file_dir_option}"; then
        log "ERROR: Failed to set dataverse.files.file.directory JVM option."
    fi
    if ! $asadmin_cmd create-jvm-options "${file_type_option}"; then
        log "ERROR: Failed to set dataverse.files.file.type JVM option."
    fi
    if ! $asadmin_cmd create-jvm-options "${file_label_option}"; then
        log "ERROR: Failed to set dataverse.files.file.label JVM option."
    fi
    if ! $asadmin_cmd create-jvm-options "${legacy_dir_option}"; then
        log "ERROR: Failed to set dataverse.files.directory (legacy) JVM option."
    fi
    if ! $asadmin_cmd create-jvm-options "${upload_redirect_option}"; then
        log "ERROR: Failed to set dataverse.files.file.upload-redirect JVM option."
    fi
    if ! $asadmin_cmd create-jvm-options "${download_redirect_option}"; then
        log "ERROR: Failed to set dataverse.files.file.download-redirect JVM option."
    fi

    # Check if database contains S3 storage identifiers, and if so, configure S3 driver for compatibility
    log "Checking if S3 storage driver is needed for existing data..."
    local s3_count
    s3_count=$(sudo -u postgres psql -t dvndb -c "SELECT COUNT(*) FROM dvobject WHERE storageidentifier LIKE 's3://%';" 2>/dev/null | xargs || echo "0")
    
    if [ "$s3_count" -gt 0 ]; then
        log "Found $s3_count objects with S3 storage identifiers. Configuring S3 storage driver for compatibility..."
        local s3_type_option="-Ddataverse.files.s3.type=s3"
        local s3_label_option="-Ddataverse.files.s3.label=s3"
        local s3_bucket_option="-Ddataverse.files.s3.bucket-name=jhu-dataverse-prod-01"
        local s3_download_option="-Ddataverse.files.s3.download-redirect=true"
        local s3_upload_option="-Ddataverse.files.s3.upload-redirect=true"
        
        # Delete and recreate S3 options
        $asadmin_cmd delete-jvm-options "${s3_type_option}"
        $asadmin_cmd delete-jvm-options "${s3_label_option}"
        $asadmin_cmd delete-jvm-options "${s3_bucket_option}"
        $asadmin_cmd delete-jvm-options "${s3_download_option}"
        $asadmin_cmd delete-jvm-options "${s3_upload_option}"
        
        if ! $asadmin_cmd create-jvm-options "${s3_type_option}"; then
            log "ERROR: Failed to set S3 type JVM option."
        fi
        if ! $asadmin_cmd create-jvm-options "${s3_label_option}"; then
            log "ERROR: Failed to set S3 label JVM option."
        fi
        if ! $asadmin_cmd create-jvm-options "${s3_bucket_option}"; then
            log "ERROR: Failed to set S3 bucket JVM option."
        fi
        if ! $asadmin_cmd create-jvm-options "${s3_download_option}"; then
            log "ERROR: Failed to set S3 download redirect JVM option."
        fi
        if ! $asadmin_cmd create-jvm-options "${s3_upload_option}"; then
            log "ERROR: Failed to set S3 upload redirect JVM option."
        fi
        log "S3 storage driver configured for compatibility with existing data."
    else
        log "No S3 storage identifiers found. S3 storage driver not needed."
    fi

    log "Local file storage JVM options have been decisively configured. A Payara restart is required for these to take effect."
}

# Function to perform post-transfer setup
post_transfer_setup() {
    echo ""
    log "=== POST-TRANSFER SETUP ==="
    
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would perform post-transfer setup."
        STATUS_POST_SETUP="DRY_RUN"
        return 0
    fi
    
    # --- 1. Final Cache Clear and Restart ---
    log "Performing final cache clear and restart..."
    if ! sudo systemctl stop payara; then
        log "Warning: Failed to stop Payara for cache clearing. Attempting to proceed."
    else
        log "Clearing Payara application cache..."
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated/*"
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache/*"
    fi

    log "Starting Payara after cache clear..."
    if ! sudo systemctl start payara; then
        log "ERROR: Failed to start Payara after clearing cache. Cannot proceed with re-indexing."
        STATUS_POST_SETUP="FAILURE"
        return 1
    fi
    
    # --- 2. Wait for Dataverse API to be ready ---
    log "Waiting for Dataverse API to become available..."
    local max_wait=300; local interval=10; local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if curl -s -k http://localhost:8080/api/v1/info/server &> /dev/null; then
            log "Dataverse API is responsive."
            break
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        if [ $elapsed -ge $max_wait ]; then
            log "ERROR: Timed out waiting for Dataverse API. Cannot re-index."
            STATUS_POST_SETUP="FAILURE"
            return 1
        fi
    done
    
    # --- 3. Clear and Rebuild Solr Index ---
    log "Clearing Solr index..."
    if ! curl -s "http://localhost:8080/api/admin/index/clear"; then
        log "Warning: Failed to clear Solr index. Re-indexing may be incomplete."
    else
        log "Solr index cleared successfully."
    fi

    log "Starting full Solr re-index..."
    local index_response
    index_response=$(curl -s "http://localhost:8080/api/admin/index")
    if [[ "$index_response" != *"started"* ]]; then
        log "Warning: Failed to start re-index command. Response: $index_response"
    else
        log "Re-index command sent. Now waiting for completion..."
        # Wait for indexing to complete
        max_wait=1800 # 30 minutes, adjust if needed
        elapsed=0
        while [ $elapsed -lt $max_wait ]; do
            if ! curl -s "http://localhost:8080/api/admin/index/status" | grep -q '"isInHeader":true'; then
                log "SUCCESS: Solr re-indexing is complete."
                break
            fi
            log "Waiting for re-index to finish... (checking in 30s)"
            sleep 30
            elapsed=$((elapsed + 30))
            if [ $elapsed -ge $max_wait ]; then
                log "ERROR: Timed out waiting for re-index to complete. Please check the Solr index manually."
                STATUS_POST_SETUP="FAILURE"
                # The script will continue, but the status is marked as failed.
            fi
        done
    fi

    log "Post-transfer setup completed."
    STATUS_POST_SETUP="SUCCESS"
    return 0
}

# Function to rollback changes
rollback_changes() {
    local failure_point="$1"
    local rollback_status=0
    log "Starting rollback from failure point: $failure_point"
    
    # Rollback database if applicable
    if [[ "$failure_point" == "database" || "$failure_point" == "all" ]]; then
        log "Attempting database rollback..."
        DB_BACKUP_FILE="$BACKUP_DIR/database_backup_$(date +%Y%m%d).sql"
        
        if [ -f "$DB_BACKUP_FILE" ]; then
            log "Found database backup at $DB_BACKUP_FILE"
            if [ -n "$DB_PASSWORD" ]; then
                if PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -f "$DB_BACKUP_FILE"; then
                    log "✓ Database successfully rolled back"
                    STATUS_DATABASE="FAILED_ROLLED_BACK_SUCCESSFULLY"
                else
                    log "✗ Database rollback failed"
                    STATUS_DATABASE="FAILED_ROLLBACK_FAILED"
                    rollback_status=1
                fi
            else
                if sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -f "$DB_BACKUP_FILE"; then
                    log "✓ Database successfully rolled back"
                    STATUS_DATABASE="FAILED_ROLLED_BACK_SUCCESSFULLY"
                else
                    log "✗ Database rollback failed"
                    STATUS_DATABASE="FAILED_ROLLBACK_FAILED"
                    rollback_status=1
                fi
            fi
        else
            log "✗ Database backup file not found at $DB_BACKUP_FILE"
            STATUS_DATABASE="FAILED_NO_BACKUP"
            rollback_status=1
        fi
    fi
    
    # Rollback config files if applicable
    if [[ "$failure_point" == "config" || "$failure_point" == "all" ]]; then
        log "Attempting configuration files rollback..."
        PAYARA_CONFIG_BACKUP_DIR="$BACKUP_DIR/config/payara"
        
        if [ -d "$PAYARA_CONFIG_BACKUP_DIR" ]; then
            log "Found Payara configuration backup at $PAYARA_CONFIG_BACKUP_DIR"
            if sudo rsync -av "$PAYARA_CONFIG_BACKUP_DIR/" "$PAYARA/glassfish/domains/domain1/config/"; then
                log "✓ Payara configuration files restored"
                sudo chown -R "$DATAVERSE_USER" "$PAYARA/glassfish/domains/domain1/config/"
                STATUS_CONFIG="FAILED_ROLLED_BACK_SUCCESSFULLY"
            else
                log "✗ Payara configuration restore failed"
                STATUS_CONFIG="FAILED_ROLLBACK_FAILED"
                rollback_status=1
            fi
        else
            log "✗ Payara configuration backup directory not found at $PAYARA_CONFIG_BACKUP_DIR"
            STATUS_CONFIG="FAILED_NO_BACKUP"
            rollback_status=1
        fi
        
        # Restore Dataverse config if it exists
        if [ -d "$BACKUP_DIR/config/dataverse" ]; then
            log "Found Dataverse configuration backup"
            if sudo rsync -av "$BACKUP_DIR/config/dataverse/" "$DATAVERSE_CONTENT_STORAGE/config/"; then
                log "✓ Dataverse configuration files restored"
                sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$DATAVERSE_CONTENT_STORAGE/config/"
            else
                log "✗ Dataverse configuration restore failed"
                rollback_status=1
            fi
        else
            log "No Dataverse configuration backup found"
        fi
    fi
    
    # Rollback external tools if applicable
    if [[ "$failure_point" == "external_tools" || "$failure_point" == "all" ]]; then
        log "Attempting external tools rollback..."
        # Clear all external tools
        if curl -X DELETE http://localhost:8080/api/admin/externalTools; then
            log "✓ External tools cleared"
            STATUS_EXTERNAL_TOOLS="FAILED_ROLLED_BACK_SUCCESSFULLY"
        else
            log "✗ Failed to clear external tools"
            STATUS_EXTERNAL_TOOLS="FAILED_ROLLBACK_FAILED"
            rollback_status=1
        fi
    fi
    
    # Rollback JVM options if applicable
    if [[ "$failure_point" == "jvm_options" || "$failure_point" == "all" ]]; then
        log "Attempting JVM options rollback..."
        # Get original JVM options from backup
        if [ -d "$BACKUP_DIR/config/payara" ]; then
            ORIGINAL_OPTIONS=$(grep -r "jvm-options" "$BACKUP_DIR/config/payara/domain.xml" | grep -oP '(?<=jvm-options>)[^<]+')
            if [ -n "$ORIGINAL_OPTIONS" ]; then
                # Remove all current JVM options
                sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" delete-jvm-options -- -Xmx512m
                sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" delete-jvm-options -- -Xms512m
                # Add original options back
                for option in $ORIGINAL_OPTIONS; do
                    if ! sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$option"; then
                        log "✗ Failed to restore JVM option: $option"
                        STATUS_JVM_OPTIONS="FAILED_ROLLBACK_FAILED"
                        rollback_status=1
                    fi
                done
                log "✓ JVM options restored"
                STATUS_JVM_OPTIONS="FAILED_ROLLED_BACK_SUCCESSFULLY"
            else
                log "✗ Could not find original JVM options in backup"
                STATUS_JVM_OPTIONS="FAILED_NO_BACKUP"
                rollback_status=1
            fi
        else
            log "✗ Payara configuration backup not found"
            STATUS_JVM_OPTIONS="FAILED_NO_BACKUP"
            rollback_status=1
        fi
    fi
    
    # Rollback metadata blocks if applicable
    if [[ "$failure_point" == "metadata_blocks" || "$failure_point" == "all" ]]; then
        log "Attempting metadata blocks rollback..."
        # Clear all metadata blocks
        if curl -X DELETE http://localhost:8080/api/metadatablocks; then
            log "✓ Metadata blocks cleared"
            STATUS_METADATA_BLOCKS="FAILED_ROLLED_BACK_SUCCESSFULLY"
        else
            log "✗ Failed to clear metadata blocks"
            STATUS_METADATA_BLOCKS="FAILED_ROLLBACK_FAILED"
            rollback_status=1
        fi
    fi
    
    # Restart services
    log "Restarting services..."
    if sudo systemctl restart payara; then
        log "✓ Payara service restarted"
    else
        log "✗ Payara service restart failed"
        rollback_status=1
    fi
    
    if sudo systemctl restart solr; then
        log "✓ Solr service restarted"
    else
        log "✗ Solr service restart failed"
        rollback_status=1
    fi
    
    # Final status report
    if [ $rollback_status -eq 0 ]; then
        log "✓ Rollback completed successfully"
    else
        log "✗ Rollback completed with errors - manual intervention may be required"
    fi
    
    return $rollback_status
}

# Function to restore from backup
restore_from_backup() {
    echo ""
    log "=== RESTORING FROM BACKUP ==="
    
    # Check required database variables
    if [ -z "$DB_SYSTEM_USER" ]; then
        log "ERROR: DB_SYSTEM_USER is not set"
        log "Please ensure DB_SYSTEM_USER is set in your .env file"
        return 1
    fi
    
    if [ -z "$DB_NAME" ]; then
        log "ERROR: DB_NAME is not set"
        log "Please ensure DB_NAME is set in your .env file"
        return 1
    fi
    
    log "Using database system user: $DB_SYSTEM_USER"
    log "Using database name: $DB_NAME"
    
    # Find the most recent backup directory
    BACKUP_DIR=""
    if [ -z "$1" ]; then
        # Look for backup directories in home directory
        BACKUP_DIR=$(find "$HOME" -maxdepth 1 -type d -name "dataverse_clone_backup_*" -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)
        
        if [ -z "$BACKUP_DIR" ]; then
            log "No backup directory found in $HOME"
            echo -n "Please enter the full path to your backup directory: "
            read -r BACKUP_DIR
        fi
    else
        BACKUP_DIR="$1"
    fi
    
    # Validate backup directory
    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR: Backup directory does not exist: $BACKUP_DIR"
        return 1
    fi
    
    # Check for required backup files
    if [ ! -f "$BACKUP_DIR/database_backup_$(date +%Y%m%d).sql" ]; then
        log "ERROR: Database backup not found in $BACKUP_DIR"
        return 1
    fi
    
    if [ ! -d "$BACKUP_DIR/config/payara" ]; then
        log "ERROR: Payara configuration backup not found in $BACKUP_DIR"
        return 1
    fi
    
    log "Found backup directory: $BACKUP_DIR"
    
    # Confirm with user
    echo "This will restore your Dataverse instance from the backup in: $BACKUP_DIR"
    echo "WARNING: This will overwrite your current configuration and database!"
    echo -n "Are you sure you want to proceed? (yes/no): "
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log "Restore cancelled by user"
        return 0
    fi
    
    # Stop services
    log "Stopping services..."
    if ! sudo systemctl stop payara; then
        log "Warning: Failed to stop Payara"
    fi
    if ! sudo systemctl stop solr; then
        log "Warning: Failed to stop Solr"
    fi
    
    # Restore database
    log "Restoring database..."
    DB_BACKUP_FILE="$BACKUP_DIR/database_backup_$(date +%Y%m%d).sql"
    
    # Verify backup file exists
    if [ ! -f "$DB_BACKUP_FILE" ]; then
        log "ERROR: Database backup file not found: $DB_BACKUP_FILE"
        return 1
    fi
    
    log "Database file exists, restoring from backup file"
    
    # Ensure the backup file is readable by postgres
    sudo chown "$DB_SYSTEM_USER:$DB_SYSTEM_USER" "$DB_BACKUP_FILE"
    sudo chmod 644 "$DB_BACKUP_FILE"
    
    # Restore the database using the preferred method
    if ! sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -f "$DB_BACKUP_FILE"; then
        log "ERROR: Failed to restore database"
        return 1
    fi
    
    # Restore Payara configuration
    log "Restoring Payara configuration..."
    if ! sudo rsync -av "$BACKUP_DIR/config/payara/" "$PAYARA/glassfish/domains/domain1/config/"; then
        log "ERROR: Failed to restore Payara configuration"
        return 1
    fi
    
    # Set proper ownership
    log "Setting proper ownership..."
    if ! sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$PAYARA/glassfish/domains/domain1/config"; then
        log "Warning: Failed to set ownership of Payara configuration"
    fi
    
    # Restore Dataverse configuration if it exists
    if [ -d "$BACKUP_DIR/config/dataverse" ]; then
        log "Restoring Dataverse configuration..."
        if ! sudo rsync -av "$BACKUP_DIR/config/dataverse/" "$DATAVERSE_CONTENT_STORAGE/config/"; then
            log "Warning: Failed to restore Dataverse configuration"
        fi
        if ! sudo chown -R "$DATAVERSE_USER:$DATAVERSE_USER" "$DATAVERSE_CONTENT_STORAGE/config"; then
            log "Warning: Failed to set ownership of Dataverse configuration"
        fi
    fi
    
    # Start services
    log "Starting services..."
    if ! sudo systemctl start solr; then
        log "Warning: Failed to start Solr"
    fi
    if ! sudo systemctl start payara; then
        log "Warning: Failed to start Payara"
    fi
    
    # Wait for Payara to be ready
    log "Waiting for Payara to be ready (checking asadmin version)..."
    MAX_RETRIES=150  # Increased timeout to 5 minutes
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" version > /dev/null 2>&1; then
            log "Payara is ready (asadmin version check successful)"
            log "Adding a short delay for Dataverse application to initialize..."
            sleep 30 # Wait 30 seconds for Dataverse to fully initialize
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Payara not ready yet (attempt $RETRY_COUNT/$MAX_RETRIES), waiting 2s..."
        sleep 2
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        log "Warning: Payara did not become ready in time"
    fi
    
    # Reindex Solr
    log "Reindexing Solr..."
    # Grab the number of items to reindex
    ITEMS_TO_REINDEX=$(curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" | jq -r '.status | to_entries[0].key' | xargs -I {} curl -s "http://localhost:8983/solr/{}/select?q=*:*&rows=0&wt=json" | jq '.response.numFound')
    log "Reindexing $ITEMS_TO_REINDEX items"
    export ITEMS_TO_REINDEX

    if ! sudo su - $DATAVERSE_USER -c "curl -s 'http://localhost:8080/api/admin/index/clear'"; then
        log_warning "Failed to clear Solr index"
    fi
    if ! sudo su - $DATAVERSE_USER -c "curl -s 'http://localhost:8080/api/admin/index'"; then
        log_warning "Failed to reindex Solr"
    else
        log "Solr reindex started. Waiting for completion..."
        if ! wait_for_dataverse_reindex_api "$ITEMS_TO_REINDEX"; then
            log_warning "Dataverse reindex (after restore) did not complete successfully or timed out. Manual check may be required."
        fi
    fi
    
    log "Restore completed successfully"
    return 0
}

# Function to configure Payara eclipselink.ddl-generation setting
configure_payara_ddl_settings() {
    echo ""
    log "=== PAYARA DDL CONFIGURATION ==="
    local payara_domain_config_dir="$PAYARA/glassfish/domains/domain1/config" # Common default
    local domain_xml_path="$payara_domain_config_dir/domain.xml"

    if ! sudo test -f "$domain_xml_path"; then # Changed to sudo test -f
        log "ERROR: domain.xml not found at $domain_xml_path (or not accessible without sudo). Cannot configure eclipselink.ddl-generation."
        return 1
    fi

    log "Configuring eclipselink.ddl-generation to 'none' in $domain_xml_path..."
    
    # Ensure DATAVERSE_USER is set for chown later
    if [ -z "$DATAVERSE_USER" ]; then
        log "Warning: DATAVERSE_USER is not set. Cannot ensure correct ownership of domain.xml after modification."
        # Attempt to get Payara run user, this is a guess
        local payara_run_user=$(ps aux | grep "[j]ava.*glassfish.jar" | awk '{print $1}' | head -n 1)
        if [ -n "$payara_run_user" ]; then
            log "Attempting to use user '$payara_run_user' for domain.xml ownership, based on running Payara process."
            DATAVERSE_USER="$payara_run_user"
        else
            log "Could not determine Payara run user. Manual ownership check of $domain_xml_path may be needed."
        fi
    fi

    local backup_ts
    backup_ts=$(date +%Y%m%d%H%M%S)
    if ! sudo cp "$domain_xml_path" "$domain_xml_path.bak_ddl_$backup_ts"; then
        log "ERROR: Failed to create backup of $domain_xml_path. Aborting DDL configuration."
        return 1
    fi
    log "Backed up $domain_xml_path to $domain_xml_path.bak_ddl_$backup_ts"

    # Define XML paths and elements
    local config_xpath="/domain/configs/config[@name='server-config']"
    local pud_xpath="$config_xpath/persistence-unit-defaults"
    local prop_name="eclipselink.ddl-generation"
    local prop_value="none"
    local prop_xpath_full="$pud_xpath/property[@name='$prop_name']"

    if command -v xmlstarlet >/dev/null 2>&1; then
        log "Using xmlstarlet to configure eclipselink.ddl-generation."

        # Ensure <persistence-unit-defaults> exists
        if ! sudo xmlstarlet sel -Q -t -c "$pud_xpath" "$domain_xml_path"; then
            log "<persistence-unit-defaults> not found. Creating it under $config_xpath."
            if ! sudo xmlstarlet ed -L -s "$config_xpath" -t elem -n "persistence-unit-defaults" -v "" "$domain_xml_path"; then
                 log "ERROR: Failed to create <persistence-unit-defaults> using xmlstarlet."
                 return 1
            fi
        fi
        
        # Now PUD exists. Check/update/add property.
        if sudo xmlstarlet sel -Q -t -c "$prop_xpath_full[@value='$prop_value']" "$domain_xml_path"; then
            log "$prop_name is already correctly set to '$prop_value'."
        elif sudo xmlstarlet sel -Q -t -c "$prop_xpath_full" "$domain_xml_path"; then
            log "Updating existing $prop_name property to '$prop_value'."
            if ! sudo xmlstarlet ed -L -u "$prop_xpath_full/@value" -v "$prop_value" "$domain_xml_path"; then
                log "ERROR: Failed to update $prop_name using xmlstarlet."
                return 1
            fi
        else
            log "Adding $prop_name property with value '$prop_value' to <persistence-unit-defaults>."
            # This sequence creates an empty property, then adds attributes one by one.
            if ! sudo xmlstarlet ed -L -s "$pud_xpath" -t elem -n "propertyTMPELEM" -v "" "$domain_xml_path" || \
               ! sudo xmlstarlet ed -L -s "$pud_xpath/propertyTMPELEM[last()]" -t attr -n "name" -v "$prop_name" "$domain_xml_path" || \
               ! sudo xmlstarlet ed -L -s "$pud_xpath/propertyTMPELEM[@name='$prop_name'][last()]" -t attr -n "value" -v "$prop_value" "$domain_xml_path" || \
               ! sudo xmlstarlet ed -L -r "$pud_xpath/propertyTMPELEM[@name='$prop_name'][last()]" -v "property" "$domain_xml_path"; then
               log "ERROR: Failed to add $prop_name property using xmlstarlet."
               return 1
            fi
        fi
        log "Successfully configured eclipselink.ddl-generation using xmlstarlet."
    else
        log "Warning: xmlstarlet not found. Attempting to use sed (less reliable for XML manipulation)."
        log "It is highly recommended to install xmlstarlet (e.g., sudo yum install xmlstarlet or sudo apt-get install xmlstarlet)."

        if sudo grep -q "<property name=\"$prop_name\" value=\"$prop_value\"/>" "$domain_xml_path"; then
            log "$prop_name seems to be already set to $prop_value (sed check)."
        elif sudo grep -q "<property name=\"$prop_name\"" "$domain_xml_path"; then
            log "Attempting to update $prop_name to $prop_value using sed."
            if ! sudo sed -i "s|<property name=\"$prop_name\" value=\"[^\"]*\"/>|<property name=\"$prop_name\" value=\"$prop_value\"/>|" "$domain_xml_path"; then
                log "ERROR: sed command to update property failed."
                return 1
            fi
        elif sudo grep -q "<persistence-unit-defaults>" "$domain_xml_path"; then
            log "Attempting to add $prop_name=$prop_value under <persistence-unit-defaults> using sed."
            # This adds the property after the <persistence-unit-defaults> opening tag.
            # It assumes <persistence-unit-defaults> does not contain other nested tags immediately after it on the same line.
            if ! sudo sed -i "/<persistence-unit-defaults>/a\\    <property name=\"$prop_name\" value=\"$prop_value\"/>" "$domain_xml_path"; then
                 log "ERROR: sed command to add property failed."
                 return 1
            fi
        else
            log "Warning: Cannot reliably add $prop_name with sed as <persistence-unit-defaults> tag was not found."
            log "Please configure manually: ensure $domain_xml_path contains:"
            log "<config name='server-config'>"
            log "  ..."
            log "  <persistence-unit-defaults>"
            log "    <property name=\"$prop_name\" value=\"$prop_value\"/>"
            log "  </persistence-unit-defaults>"
            log "  ..."
            log "</config>"
            return 1 # Indicate failure to auto-configure
        fi
        log "Configuration attempt with sed completed. Please verify $domain_xml_path manually."
    fi

    if [ -n "$DATAVERSE_USER" ]; then
        log "Ensuring $DATAVERSE_USER owns $domain_xml_path..."
        if ! sudo chown "$DATAVERSE_USER:$DATAVERSE_USER" "$domain_xml_path"; then
            log "Warning: Failed to set ownership of $domain_xml_path to $DATAVERSE_USER."
            log "Please ensure $domain_xml_path is readable by the Payara server user."
        fi
    fi
    
    log "Payara eclipselink.ddl-generation configuration completed. A Payara restart is needed for changes to take effect."
    return 0
}

# Function to get a single raw value from a query
get_sql_value() {
    local query="$1"
    local psql_output
    if [ -n "$DB_PASSWORD" ]; then
        export PGPASSWORD="$DB_PASSWORD"
        psql_output=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -t -c "$query" 2>&1)
        unset PGPASSWORD
    else
        psql_output=$(sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -t -c "$query" 2>&1)
    fi
    # Trim leading/trailing whitespace
    echo "$psql_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Function to run a SELECT query and display results
run_select_query() {
    local query="$1"
    log "Running query to display to user." # Don't log query itself, it can be large
    # Using psql with -P format=aligned -P null='(null)' for better readability
    if [ -n "$DB_PASSWORD" ]; then
        export PGPASSWORD="$DB_PASSWORD"
        sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -P format=aligned -P null='(null)' -c "$query"
        local psql_exit_code=$?
        unset PGPASSWORD
    else
        sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -P format=aligned -P null='(null)' -c "$query"
        local psql_exit_code=$?
    fi
    return $psql_exit_code
}

# Function to check template integrity
check_template_integrity() {
    echo ""
    log "=== METADATA TEMPLATE INTEGRITY CHECK ==="

    # List available templates
    local list_templates_query="SELECT id, name FROM public.template ORDER BY name;"
    echo "Available templates:"
    run_select_query "$list_templates_query"

    if [ $? -ne 0 ]; then
        log_warning "Could not fetch list of templates."
        # Don't exit, maybe user knows the name
    fi

    echo ""
    echo -n "Please enter the name or number of the template to check (or press Enter to cancel): "
    read -r template_name

    if [ -z "$template_name" ]; then
        log "Template check cancelled."
        return 0
    fi
    # If the user enters a number, convert it to a name
    if [[ "$template_name" =~ ^[0-9]+$ ]]; then
        template_name_from_id=$(get_sql_value "SELECT name FROM public.template WHERE id = $template_name;")
        if [ -n "$template_name_from_id" ]; then
            log "Checking template ID $template_name which is named '$template_name_from_id'"
            template_name="$template_name_from_id"
        else
            log_warning "No template found with ID $template_name."
        return 1
    fi
    fi
    # Sanitize input to prevent injection. Although it's used in '', it's good practice.
    # Simple sanitization: remove single quotes, backslashes, and semicolons.
    template_name=$(echo "$template_name" | sed "s/[';\\\\]//g")

    log "Checking template configuration for: $template_name"
    echo "----------------------------------------"
  
    # Check template association with dataverse
    local query="
    SELECT 
        t.id as template_id,
        t.name as template_name,
        d.id as dataverse_id,
        d.name as dataverse_name,
        d.defaulttemplate_id
    FROM 
        public.template t
    LEFT JOIN 
        public.dataverse d ON t.dataverse_id = d.id
    WHERE 
        t.name = '$template_name';"
  
    echo "Template-Dataverse Association (is this template the default for any dataverse?):"
    run_select_query "$query"
    echo "----------------------------------------"
  
    # Check if the dataverses using this template have the required metadatablocks enabled
    query="
    WITH TemplateDataverses AS (
        SELECT d.id as dataverse_id, d.name as dataverse_name
        FROM public.template t
        JOIN public.dataverse d ON t.id = d.defaulttemplate_id
        WHERE t.name = '$template_name'
        UNION
        SELECT d.id, d.name
        FROM public.template t
        JOIN public.dataverse d ON t.dataverse_id = d.id
        WHERE t.name = '$template_name'
    ),
    TemplateMetadataBlocks AS (
        SELECT DISTINCT dft.metadatablock_id
        FROM public.template t
        JOIN public.datasetfield df ON t.id = df.template_id
        JOIN public.datasetfieldtype dft ON df.datasetfieldtype_id = dft.id
        WHERE t.name = '$template_name'
    )
    SELECT 
        td.dataverse_name,
        mb.name as metadatablock_name,
        CASE 
            WHEN dmb.metadatablocks_id IS NOT NULL THEN 'ENABLED'
            ELSE 'MISSING'
        END as status
    FROM TemplateDataverses td
    CROSS JOIN TemplateMetadataBlocks tmb
    JOIN public.metadatablock mb ON tmb.metadatablock_id = mb.id
    LEFT JOIN public.dataverse_metadatablock dmb 
        ON tmb.metadatablock_id = dmb.metadatablocks_id AND td.dataverse_id = dmb.dataverse_id
    ORDER BY td.dataverse_name, mb.name;
    "
  
    echo "Metadata Block Associations for Dataverses using this template:"
    run_select_query "$query"
    echo "----------------------------------------"
  
    # Check field input levels for the dataverses using this template
    query="
    WITH TemplateDataverses AS (
        SELECT d.id as dataverse_id, d.name as dataverse_name
        FROM public.template t
        JOIN public.dataverse d ON t.id = d.defaulttemplate_id
        WHERE t.name = '$template_name'
        UNION
        SELECT d.id, d.name
        FROM public.template t
        JOIN public.dataverse d ON t.dataverse_id = d.id
        WHERE t.name = '$template_name'
    )
    SELECT
        dft.name as field_name,
        td.dataverse_name,
        -- If dfil is null, it means the field is optional and included by default
        COALESCE(dfil.include, true) as included,
        COALESCE(dfil.required, false) as required
    FROM public.template t
    JOIN public.datasetfield df ON t.id = df.template_id
    JOIN public.datasetfieldtype dft ON df.datasetfieldtype_id = dft.id
    -- All dataverses using the template
    CROSS JOIN TemplateDataverses td
    -- Find the specific input level for that field in that dataverse
    LEFT JOIN public.dataversefieldtypeinputlevel dfil 
        ON dft.id = dfil.datasetfieldtype_id AND td.dataverse_id = dfil.dataverse_id
    WHERE 
        t.name = '$template_name'
    ORDER BY 
        td.dataverse_name, dft.displayorder;
    "
    
    echo "Field Input Levels for Dataverses using this template:"
    run_select_query "$query"
    log "Template integrity check finished."
    return 0
}

# Function to compare domain.xml between production and local
compare_domain_configs() {
    echo ""
    log "=== DOMAIN.XML CONFIGURATION COMPARISON ==="
    local prod_ssh_target="$1"
    local local_domain_xml="/usr/local/payara6/glassfish/domains/domain1/config/domain.xml"
    local temp_dir

    if ! temp_dir=$(mktemp -d); then
        log "ERROR: Could not create temporary directory for config comparison."
        return 1
    fi

    log "Temporary directory created at: $temp_dir"
    local prod_domain_xml_path="$temp_dir/domain.xml.prod"

    log "Fetching domain.xml from production server: $prod_ssh_target"
    if ! scp "$prod_ssh_target:$local_domain_xml" "$prod_domain_xml_path"; then
        log "ERROR: Failed to fetch domain.xml from production server."
        rm -rf "$temp_dir"
        return 1
    fi

    log "Comparing local domain.xml with production version..."
    local diff_output
    diff_output=$(diff -u "$local_domain_xml" "$prod_domain_xml_path")

    if [ -z "$diff_output" ]; then
        log "✅ SUCCESS: Local domain.xml is identical to production."
    else
        log "⚠️  WARNING: Differences found between local and production domain.xml."
        echo ""
        log "--- DIFF START ---"
        echo "$diff_output" | tee -a "$LOGFILE"
        log "--- DIFF END ---"
        echo ""
        echo "Differences between the local and production domain.xml have been logged."
    fi

    rm -rf "$temp_dir"
    log "Comparison complete."
    return 0
}

# Function to intelligently sync system-properties from production domain.xml
sync_domain_properties() {
    echo ""
    log "=== INTELLIGENT DOMAIN.XML PROPERTY SYNC ==="
    local prod_ssh_target="$1"
    local local_domain_xml="/usr/local/payara6/glassfish/domains/domain1/config/domain.xml"
    local temp_dir
    local asadmin_cmd="sudo -u $DATAVERSE_USER /usr/local/payara6/bin/asadmin"

    if ! temp_dir=$(mktemp -d); then
        log "ERROR: Could not create temp dir for property sync."
        return 1
    fi

    local prod_domain_xml_path="$temp_dir/domain.xml.prod"

    log "Fetching domain.xml from production to analyze its system properties..."
    if ! scp "$prod_ssh_target:$local_domain_xml" "$prod_domain_xml_path"; then
        log "ERROR: Failed to fetch domain.xml from production."
        rm -rf "$temp_dir"
        return 1
    fi

    log "Extracting non-storage system properties from production config..."
    # Use grep to find system-property lines, then grep -v to exclude storage-related ones
    local props_to_sync
    props_to_sync=$(grep '<system-property ' "$prod_domain_xml_path" | grep -v -e 'dataverse.files' -e 'S3')

    if [ -z "$props_to_sync" ]; then
        log "No non-storage system properties to sync from production."
        rm -rf "$temp_dir"
        return 0
    fi

    log "The following non-storage properties will be synced from production:"
    echo "$props_to_sync"

    # Loop through each property and apply it using asadmin
    echo "$props_to_sync" | while IFS= read -r prop_line; do
        local prop_name
        local prop_value
        prop_name=$(echo "$prop_line" | sed -n 's/.*name="\([^"]*\)".*/\1/p')
        prop_value=$(echo "$prop_line" | sed -n 's/.*value="\([^"]*\)".*/\1/p')

        if [ -n "$prop_name" ] && [ -n "$prop_value" ]; then
            log "Syncing property: $prop_name=$prop_value"
            # Use asadmin to set the property. This is safer than editing the file directly.
            # It handles creating or updating the property.
            if ! $asadmin_cmd set-system-properties "${prop_name}=${prop_value}"; then
                log "WARNING: Failed to set system property '$prop_name'."
            fi
        fi
    done

    rm -rf "$temp_dir"
    log "Intelligent domain property sync complete. A Payara restart is needed."
    return 0
}

# Main function
main() {
    # Initialize status variables
    SCRIPT_OVERALL_STATUS="SUCCESS"
    STATUS_DATABASE="NOT_ATTEMPTED"
    STATUS_FILES="NOT_ATTEMPTED"
    STATUS_SOLR="NOT_ATTEMPTED"
    STATUS_COUNTER="NOT_ATTEMPTED"
    STATUS_EXTERNAL_TOOLS="NOT_ATTEMPTED"
    STATUS_JVM_OPTIONS="NOT_ATTEMPTED"
    STATUS_POST_SETUP="NOT_ATTEMPTED"
    STATUS_TEMPLATE_CHECK="NOT_ATTEMPTED"

    # Check version compatibility before proceeding
    check_versions

    # Parse command-line arguments
    for arg in "$@"; do
        case $arg in
            --dry-run)
                DRY_RUN=true
                ;;
            --verbose)
                VERBOSE=true
                ;;
            --debug)
                DEBUG=true
                ;;
            --skip-db)
                SKIP_DB=true
                STATUS_DATABASE="SKIPPED"
                ;;
            --skip-files)
                SKIP_FILES=true
                STATUS_FILES="SKIPPED"
                ;;
            --skip-solr)
                SKIP_SOLR=true
                STATUS_SOLR="SKIPPED"
                ;;
            --skip-counter)
                SKIP_COUNTER=true
                STATUS_COUNTER="SKIPPED"
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                ;;
            --skip-external-tools)
                SKIP_EXTERNAL_TOOLS=true
                STATUS_EXTERNAL_TOOLS="SKIPPED"
                ;;
            --skip-jvm-options)
                SKIP_JVM_OPTIONS=true
                STATUS_JVM_OPTIONS="SKIPPED"
                ;;
            --skip-post-setup)
                SKIP_POST_SETUP=true
                STATUS_POST_SETUP="SKIPPED"
                ;;
            --skip-template-check)
                SKIP_TEMPLATE_CHECK=true
                STATUS_TEMPLATE_CHECK="SKIPPED"
                ;;
            --cleanup-backups)
                CLEANUP_BACKUPS=true
                ;;
            --restore)
                RESTORE=true
                ;;
            --restore-path=*)
                RESTORE_PATH="${arg#*=}"
                ;;
            --help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --dry-run          Show what would be done without making changes"
                echo "  --verbose          Show detailed output"
                echo "  --debug            Show debug output"
                echo "  --skip-db          Skip database sync"
                echo "  --skip-files       Skip files sync"
                echo "  --skip-solr        Skip Solr sync"
                echo "  --skip-counter     Skip counter processor sync"
                echo "  --skip-backup      Skip backup of clone server before sync"
                echo "  --skip-external-tools    Skip external tools sync"
                echo "  --skip-jvm-options      Skip JVM options sync"
                echo "  --skip-post-setup      Skip post-transfer setup"
                echo "  --skip-template-check   Skip template integrity check"
                echo "  --cleanup-backups  Clean up old backups before starting"
                echo "  --restore          Restore from backup"
                echo "  --restore-path=PATH  Specify backup path for restore"
                echo "  --help             Show this help message"
                exit 0
                ;;
            --full-copy)
                FULL_COPY=true
                ;;
            --restore-from-backup)
                RESTORE_FROM_BACKUP=true; BACKUP_PATH="${2:-}"; shift ;;
            --configure-ddl)
                CONFIGURE_DDL=true
                ;;
            --compare-configs)
                COMPARE_CONFIGS=true
                ;;
            -h | --help)
                print_help; exit 0 ;;
            *)
                echo "Unknown option: $1"; print_help; exit 1 ;;
        esac
        shift
    done

    # Initialize variables
    DRY_RUN=${DRY_RUN:-false}
    VERBOSE=${VERBOSE:-false}
    DEBUG=${DEBUG:-false}
    SKIP_DB=${SKIP_DB:-false}
    SKIP_FILES=${SKIP_FILES:-false}
    SKIP_SOLR=${SKIP_SOLR:-false}
    SKIP_COUNTER=${SKIP_COUNTER:-false}
    SKIP_BACKUP=${SKIP_BACKUP:-false}
    SKIP_EXTERNAL_TOOLS=${SKIP_EXTERNAL_TOOLS:-false}
    SKIP_JVM_OPTIONS=${SKIP_JVM_OPTIONS:-false}
    SKIP_POST_SETUP=${SKIP_POST_SETUP:-false}
    SKIP_TEMPLATE_CHECK=${SKIP_TEMPLATE_CHECK:-false}
    CLEANUP_BACKUPS=${CLEANUP_BACKUPS:-false}
    RESTORE=${RESTORE:-false}

    # Handle restore operation
    if [ "$RESTORE" = true ]; then
        if restore_from_backup "$RESTORE_PATH"; then
            STATUS_RESTORE="SUCCESS"
        else
            STATUS_RESTORE="FAILED"
            SCRIPT_OVERALL_STATUS="FAILURE"
        fi
        print_final_summary "$DRY_RUN"
        return $?
    fi

    # Clean up old backups if requested
    if [ "$CLEANUP_BACKUPS" = true ]; then
        cleanup_old_backups "$HOME"
    fi

    # Rotate logs to prevent excessive file size
    if [ -f "$LOGFILE" ] && [ $(stat -c%s "$LOGFILE") -gt 10485760 ]; then
        mv "$LOGFILE" "${LOGFILE}.old"
    fi

    # Lock file to prevent concurrent runs
    LOCK_FILE="/tmp/fetch_prod_lock"
    if [ -e "$LOCK_FILE" ]; then
        log "ERROR: Another instance of this script seems to be running. If not, remove $LOCK_FILE"
        exit 1
    fi
    touch "$LOCK_FILE"

    # Set up trap to remove lock file on exit
    trap 'rm -f "$LOCK_FILE"; log "Lock file removed"' EXIT

    # Check required commands
    check_required_commands

    # Fetch production S3 JVM options early and check versions
    # This populates PROD_S3_OPTIONS for use in prompt_s3_configuration
    pre_sync_fetch_prod_jvm_s3_options
    check_versions # Moved after pre_sync_fetch to ensure PROD_PAYARA_PATH logic is sound

    # Configure Payara DDL settings (best effort)
    if ! configure_payara_ddl_settings; then
        log "Warning: Failed to automatically configure Payara DDL settings. Deployment issues may persist."
    fi

    # Check required environment variables
    DATAVERSE_VARS=(
        "DOMAIN"
        "PAYARA"
        "DATAVERSE_USER"
        "SOLR_USER"
        "DATAVERSE_CONTENT_STORAGE"
        "SOLR_PATH"
        "DATAVERSE_API_KEY" # Added for enabling metadata blocks
    )

    PRODUCTION_VARS=(
        "PRODUCTION_SERVER"
        "PRODUCTION_DOMAIN"
        "PRODUCTION_DATAVERSE_USER"
        "PRODUCTION_SOLR_USER"
        "PRODUCTION_DATAVERSE_CONTENT_STORAGE"
        "PRODUCTION_SOLR_PATH"
    )

    DB_VARS=(
        "PRODUCTION_SERVER" 
        "PRODUCTION_DB_HOST" 
        "DB_HOST" 
        "DB_NAME" 
        "DB_USER"
        "DB_SYSTEM_USER"
        "PRODUCTION_DB_NAME" 
        "PRODUCTION_DB_USER"
        "PRODUCTION_DB_SYSTEM_USER"
    )

    # Check all required variable groups
    log "Verifying environment variables..."
    if ! check_required_vars "local Dataverse" "${DATAVERSE_VARS[@]}" || \
       ! check_required_vars "production Dataverse" "${PRODUCTION_VARS[@]}" || \
       ! check_required_vars "database connection" "${DB_VARS[@]}"; then
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    # Set default for FULL_COPY if not defined
    if [[ -z "$FULL_COPY" ]]; then
        FULL_COPY="false"
        log "FULL_COPY not defined in .env, defaulting to 'false' (limited file copy)"
    fi

    # Convert to lowercase for comparison
    FULL_COPY=$(echo "$FULL_COPY" | tr '[:upper:]' '[:lower:]')

    # Set SSH user for production server
    if [[ -z "$PRODUCTION_SSH_USER" ]]; then
        PRODUCTION_SSH_USER=$(whoami)
        log "PRODUCTION_SSH_USER not defined, using current user: $PRODUCTION_SSH_USER"
    fi

    # Safety check - confirm we're not running on production
    log "Performing safety check to ensure this is not the production server..."
    DOMAIN_XML_PATH="$PAYARA/glassfish/domains/domain1/config/domain.xml"
    DOMAIN_XML_EXISTS=$(sudo ls -l "$DOMAIN_XML_PATH" || echo "not found")
    log "DOMAIN_XML_PATH: $DOMAIN_XML_PATH"
    log "DOMAIN_XML_EXISTS: $DOMAIN_XML_EXISTS"
    if [ "$DOMAIN_XML_EXISTS" != "not found" ]; then
        # Extract FQDN from domain.xml
        LOCAL_FQDN=$(sudo grep -oP 'dataverse\.fqdn=\K[^<>"[:space:]]+' "$DOMAIN_XML_PATH" || echo "unknown")

        if [[ "$LOCAL_FQDN" == "$PRODUCTION_DOMAIN" ]]; then
            log "ERROR: This script detected this is the PRODUCTION server (FQDN: $LOCAL_FQDN matches PRODUCTION_DOMAIN: $PRODUCTION_DOMAIN)!"
            log "This script should NOT be run on the production server. Exiting."
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
        
        log "Safety check passed - Running on non-production server (FQDN: $LOCAL_FQDN)"
    else
        log "WARNING: Could not verify server identity from domain.xml. Proceeding with caution."
        log "If this is the production server, please abort now."
        echo -n "Are you SURE this is NOT the production server? Type 'yes' to continue: "
        read -r PRODUCTION_CONFIRMATION
        if [[ "$PRODUCTION_CONFIRMATION" != "yes" ]]; then
            log "Operation cancelled by user"
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 0
        fi
    fi

    log "Checking SSL certificate validity..."
    CERT_EXPIRED=false
    check_ssl_certificates "$DOMAIN"

    # Safety check - ensure we're not restoring to production database
    if [[ "$DB_HOST" == "$PRODUCTION_DOMAIN" || "$DB_HOST" == "$PRODUCTION_DB_HOST" ]]; then
        log "ERROR: Your DB_HOST ${DB_HOST} is set to the production domain or database host! "
        log " This would cause the script to restore TO the production database rather than FROM it. "
        log "Please update your .env file to set DB_HOST to localhost or your clone server's database host. "
        log "Example: DB_HOST=localhost"
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    # Testing remote connectivity - SSH and database
    log "Testing SSH connection to production server..."
    # Check network connectivity first
    if ! check_network_connectivity "$PRODUCTION_SERVER"; then
        log "ERROR: Cannot establish network connectivity to production server. Please check network settings and try again."
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    if ! verify_ssh_connectivity "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER"; then
        log "ERROR: Cannot connect to production server. Check SSH keys and connectivity."
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    # Test database connection
    log "Testing database connections..."
    if [ -n "$DB_PASSWORD" ]; then
        PGPASSWORD="$DB_PASSWORD" sudo -u "$DB_SYSTEM_USER" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" -v ON_ERROR_STOP=1 --set AUTOCOMMIT=off --set TIMEOUT=30
    else
        sudo -u "$DB_SYSTEM_USER" psql -d "$DB_NAME" -c "SELECT 1" -v ON_ERROR_STOP=1 --set AUTOCOMMIT=off --set TIMEOUT=30
    fi
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to connect to local database"
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    # Validation for critical paths
    log "Validating critical paths..."
    for path_var in DATAVERSE_CONTENT_STORAGE SOLR_PATH; do
        if [ -n "${!path_var}" ] && [ ! -d "${!path_var}" ]; then
            log "ERROR: Directory ${!path_var} does not exist or is not accessible."
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
    done

    # Create backup if not skipped
    if [ "$SKIP_BACKUP" = false ] && [ "$DRY_RUN" = false ]; then
        if ! create_backup; then
            log "ERROR: Failed to create backup. Aborting."
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
    fi

    # --- STOP PAYARA BEFORE ANY MAJOR OPERATIONS ---
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would stop Payara service now."
    else
        log "Stopping Payara service before sync operations..."
        if ! sudo systemctl stop payara; then
            log "Warning: Failed to stop Payara. Database operations may fail."
        else
            log "Payara stopped successfully."
        fi
    fi
    # --- END PAYARA STOP ---

    # Step 1: Database Operations
    if [ "$SKIP_DB" = false ]; then
        if ! sync_database; then
            log "ERROR: Database sync failed. Aborting."
            SCRIPT_OVERALL_STATUS="FAILURE"
            STATUS_DATABASE="FAILED"
            print_final_summary "$DRY_RUN"
            # Attempt to restart payara on failure
            sudo systemctl start payara &>/dev/null
            exit 1
        fi
        STATUS_DATABASE="SUCCESS"
    fi

    # After DB sync, and after S3/local choice has been made, configure JVM if needed
    if [ "$S3_CONFIG_CHOICE" == "2" ] && [ "$DRY_RUN" = false ]; then
        log "Choice was made to use local file storage; configuring JVM options now."
        if ! configure_local_storage_jvm_options; then
            log_warning "Configuration of local storage JVM options failed. Storage may not work correctly."
        fi
    fi

    if [ "$SKIP_FILES" = false ]; then
        if ! sync_files; then
            log "ERROR: File sync failed. Rolling back..."
            STATUS_FILES="FAILED_ROLLED_BACK"
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
        STATUS_FILES="SUCCESS"
    fi

    if [ "$SKIP_SOLR" = false ]; then
        if ! sync_solr; then
            log "ERROR: Solr sync failed. Rolling back..."
            STATUS_SOLR="FAILED_ROLLED_BACK"
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
        STATUS_SOLR="SUCCESS"
    fi

    if [ "$SKIP_COUNTER" = false ]; then
        if ! sync_counter_processor; then
            log "ERROR: Counter processor sync failed. Rolling back..."
            STATUS_COUNTER="FAILED_ROLLED_BACK"
            SCRIPT_OVERALL_STATUS="FAILURE"
            print_final_summary "$DRY_RUN"
            exit 1
        fi
        STATUS_COUNTER="SUCCESS"
    fi

    # Step: JVM Options Sync
    if [ "$SKIP_JVM_OPTIONS" = false ]; then
        verify_jvm_options
    fi

    # Restart Payara now that core syncs are done
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would start Payara service now."
    else
        start_payara
        if [ $? -ne 0 ]; then
            log "Critical error: Payara failed to start. Aborting subsequent steps."
            # You might want to set remaining statuses to FAILURE or SKIPPED here
            exit 1 # Or handle this less abruptly
        fi
    fi

    if [ "$SKIP_EXTERNAL_TOOLS" = false ]; then
        sync_external_tools
        STATUS_EXTERNAL_TOOLS=$([ $? -eq 0 ] && echo "SUCCESS" || echo "FAILURE")
    else
        log "Skipping external tools sync as requested."
        STATUS_EXTERNAL_TOOLS="SKIPPED"
    fi

    if [ "$SKIP_POST_SETUP" = false ]; then
        post_transfer_setup
        STATUS_POST_SETUP=$([ $? -eq 0 ] && echo "SUCCESS" || echo "FAILURE")
    else
        log "Skipping post-transfer setup as requested."
        STATUS_POST_SETUP="SKIPPED"
    fi

    # Clean up
    rm -f "$LOCK_FILE"

    log "Checking to see if dataverse is running and the page /dataverse/root?q= loads..."
    local max_retries=6  # 6 retries * 5 seconds = 30 seconds total
    local retry_count=0
    local dataverse_ok=false

    log "Checking if Dataverse is running and the page /dataverse/root?q= loads..."
    while [ $retry_count -lt $max_retries ]; do
        if curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/dataverse/root?q=" | grep -q "200"; then
            dataverse_ok=true
            break
        fi
        log "Waiting for Dataverse to be ready (attempt $((retry_count+1))/$max_retries)... "
        sleep 5
        retry_count=$((retry_count+1))
    done

    if [ "$dataverse_ok" = true ]; then
        log "Dataverse is running and the page /dataverse/root?q= loads. This is a good sign."
    else
        log "ERROR: Dataverse is not running or the page /dataverse/root?q= does not load after 30 seconds. Please check the logs for errors."
        SCRIPT_OVERALL_STATUS="FAILURE"
        print_final_summary "$DRY_RUN"
        exit 1
    fi

    log "Sync completed successfully"

    # Template Integrity Check
    if [ "$SKIP_TEMPLATE_CHECK" = false ]; then
        check_template_integrity
        STATUS_TEMPLATE_CHECK="SUCCESS" # Mark as run. The function itself just logs info.
    fi

    print_final_summary "$DRY_RUN"

    # Execute comparison if requested and exit
    if [ "$COMPARE_CONFIGS" = true ]; then
        log "Starting configuration comparison as requested."
        sync_domain_properties "$PRODUCTION_SSH_USER@$PRODUCTION_SERVER"
        log "Comparison finished. Exiting script as requested."
        exit 0
    fi

    return 0
}

# Run the main function
main "$@"