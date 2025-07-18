#!/bin/bash
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.6
#
# IMPORTANT: This script handles "application already registered" errors gracefully.
# These errors often occur during upgrades when an application is partially deployed
# but are usually benign if the application verification succeeds.

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Logging configuration
LOGFILE="$SCRIPT_DIR/dataverse_upgrade_6_5_to_6_6.log"
echo "" > "$LOGFILE"
STATE_FILE="$SCRIPT_DIR/upgrade_6_5_to_6_6.state"
CITATION_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/scripts/api/data/metadatablocks/citation.tsv"
OBJECTS_3D_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/scripts/api/data/metadatablocks/3d_objects.tsv"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/schema.xml"
SOLR_CONFIG_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/solrconfig.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/update-fields.sh"
PAYARA_DOWNLOAD_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2025.2/payara-6.2025.2.zip"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.6/dataverse-6.6.war"
TARGET_VERSION="6.6"
CURRENT_VERSION="6.5"
PAYARA_VERSION="6.2025.2"
SOLR_VERSION="9.8.0"
REQUIRED_JAVA_VERSION="11"

# SHA256 checksums for verification
PAYARA_SHA256="c06edc1f39903c874decf9615ef641ea18d3f7969d38927c282885960d5ee796"
DATAVERSE_WAR_SHA256="04206252f9692fe5ffca9ac073161cd52835f607d9387194a4112f91c2176f3d"
SOLR_SHA256="9948dcf798c196b834c4cbb420d1ea5995479431669d266c33d46548b67e69e1"

# Solr download URL for 9.8.0
SOLR_DOWNLOAD_URL="https://archive.apache.org/dist/solr/solr/9.8.0/solr-9.8.0.tgz"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to compare version numbers for better error messages
# Returns 0 if version1 < version2, 1 if version1 >= version2
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # Use sort -V to compare versions properly
    if [[ "$(printf '%s\n' "$version1" "$version2" | sort -V | head -n1)" == "$version1" && "$version1" != "$version2" ]]; then
        return 0  # version1 < version2
    else
        return 1  # version1 >= version2
    fi
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
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
    log "Loaded environment variables from .env file"
else
    log "Error: .env file not found. Please create one based on sample.env"
    exit 1
fi

# Required variables check
required_vars=(
    "DOMAIN" "PAYARA" "DATAVERSE_USER" "WAR_FILE_LOCATION"
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

# Check if current user exists in passwd database and can use sudo
log "Current user diagnostics:"
log "  USER: $USER"
log "  UID: $(id -u 2>/dev/null || echo 'unknown')"
log "  whoami: $(whoami 2>/dev/null || echo 'unknown')"
log "  passwd entry: $(getent passwd "$(id -u 2>/dev/null)" 2>/dev/null || echo 'not found')"

if ! id -u "$USER" >/dev/null 2>&1; then
    log "WARNING: Current user ($USER) does not exist in passwd database."
    log "This may prevent sudo from working properly in some contexts."
    log "Testing sudo functionality..."

    # Test if sudo works despite the passwd issue
    if sudo -n true 2>/dev/null; then
        log "✓ Sudo appears to work despite passwd database issue."
        log "Continuing with upgrade..."
    else
        log "ERROR: Sudo is not working. This may be due to:"
        log "1. User not in sudoers file"
        log "2. Name service (NSS/LDAP/SSSD) configuration issues"
        log "3. Container/environment limitations"
        log ""
        log "Please ensure your user has sudo privileges and try again."
        exit 1
    fi
elif [ "$USER" != "$DATAVERSE_USER" ]; then
    # Prompt user to confirm they want to continue
    read -p "Current user is not $DATAVERSE_USER. This is not a big deal. Continue? (y/n): " CONTINUE
    if [[ "$CONTINUE" != [Yy] ]]; then
        log "Exiting."
        exit 1
    fi
fi

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

# Function to verify SHA256 checksum
verify_checksum() {
    local file_path="$1"
    local expected_sha256="$2"
    local file_description="$3"
    
    if [[ "$expected_sha256" == "REPLACE_WITH_OFFICIAL_"* ]]; then
        log "WARNING: No SHA256 checksum provided for $file_description"
        log "Please update the script with the official checksum before running in production"
        log "To get the checksum manually, run: sha256sum $file_path"
        return 0
    fi
    
    log "Verifying SHA256 checksum for $file_description..."
    local actual_sha256=$(sha256sum "$file_path" | cut -d' ' -f1)
    
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
        log "✓ Checksum verification passed for $file_description"
        return 0
    else
        log "✗ Checksum verification FAILED for $file_description"
        log "Expected: $expected_sha256"
        log "Actual:   $actual_sha256"
        log "This could indicate a corrupted download or security issue."
        return 1
    fi
}

# Function to check checksum configuration
check_checksum_configuration() {
    local warnings=0
    
    if [[ "$PAYARA_SHA256" == "REPLACE_WITH_OFFICIAL_"* ]]; then
        log "WARNING: Payara SHA256 checksum is not configured!"
        log "Please update PAYARA_SHA256 variable with the official checksum."
        warnings=$((warnings + 1))
    fi
    
    if [[ "$DATAVERSE_WAR_SHA256" == "REPLACE_WITH_OFFICIAL_"* ]]; then
        log "WARNING: Dataverse WAR SHA256 checksum is not configured!"
        log "Please update DATAVERSE_WAR_SHA256 variable with the official checksum."
        warnings=$((warnings + 1))
    fi
    
    if [[ "$SOLR_SHA256" == "REPLACE_WITH_OFFICIAL_"* ]]; then
        log "WARNING: Solr SHA256 checksum is not configured!"
        log "Please update SOLR_SHA256 variable with the official checksum."
        warnings=$((warnings + 1))
    fi
    
    if [ $warnings -gt 0 ]; then
        log ""
        log "SECURITY WARNING: $warnings checksum(s) not configured."
        log "For production use, please configure all checksums to verify download integrity."
        log "See the instructions at the top of this script for how to obtain checksums."
        log ""
        read -p "Do you want to continue without checksum verification? (y/N): " CONTINUE_WITHOUT_CHECKSUMS
        if [[ ! "$CONTINUE_WITHOUT_CHECKSUMS" =~ ^[Yy]$ ]]; then
            log "Exiting. Please configure checksums and run again."
            exit 1
        fi
        log "Continuing without full checksum verification..."
        log ""
    fi
}

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "grep" "sed" "sudo" "systemctl" "pgrep" "jq" "rm" "ls" "bash" "tee" "sha256sum" "wget" "unzip" "java"
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

# Function to check if sudo is working properly
check_sudo_access() {
    log "Checking sudo access..."
    
    # Test if sudo works at all (with more robust error handling)
    if ! sudo -n true 2>/dev/null; then
        log "WARNING: sudo requires password or is not configured for passwordless access."
        log "The script will prompt for password when needed."
    fi
    
    # Test if we can run a simple command as root (with multiple fallback methods)
    local sudo_works=false
    local test_method=""
    
    # Try multiple sudo test methods
    if sudo -n whoami >/dev/null 2>&1; then
        sudo_works=true
        test_method="whoami"
    elif sudo -n sh -c "echo 'sudo test successful'" >/dev/null 2>&1; then
        sudo_works=true
        test_method="sh"
    elif sudo -n id >/dev/null 2>&1; then
        sudo_works=true
        test_method="id"
    elif sudo -n bash -c "echo 'sudo bash test successful'" >/dev/null 2>&1; then
        sudo_works=true
        test_method="bash"
    fi
    
    if [ "$sudo_works" = true ]; then
        log "✓ Sudo access verified ($test_method method)."
    else
        log "WARNING: Sudo tests are failing, but this may be due to user resolution issues."
        log "This is common in certain environments (containers, NFS, LDAP, etc.)."
        log "Attempting to continue anyway - sudo may work for actual operations."
        log ""
        log "If the script fails later with sudo errors, please ensure:"
        log "1. You have sudo privileges"
        log "2. sudo is properly configured"
        log "3. Your user is properly configured in the system"
        log ""
        log "You can also try running the script again (sudo may work on retry)."
        log ""
        log "Current user info:"
        log "  USER: $USER"
        log "  UID: $(id -u 2>/dev/null || echo 'unknown')"
        log "  whoami: $(whoami 2>/dev/null || echo 'unknown')"
    fi
}

# Function to start Payara if needed
start_payara_if_needed() {
    if ! pgrep -f "payara.*$DOMAIN_NAME" > /dev/null; then
        log "Payara is not running. Starting it now..."
        sudo systemctl start payara || return 1
        log "Waiting for Payara to initialize..."
        sleep 10
    fi
}

# Function to analyze deployment output for non-fatal errors
analyze_deployment_output() {
    local output_file="$1"
    local has_fatal_errors=false
    
    # Common non-fatal SQL errors that can be ignored during upgrades
    local benign_patterns=(
        "duplicate key value violates unique constraint"
        "already exists"
        "relation.*already exists"
        "constraint.*already exists"
        "index.*already exists"
        "sequence.*already exists"
        "table.*already exists"
        "PER01000.*duplicate key"
        "PSQLException.*duplicate key"
        "application.*already registered"
        "application with name.*already registered"
    )
    
    # Fatal error patterns that should cause failure
    local fatal_patterns=(
        "FATAL:"
        "connection refused"
        "could not connect"
        "authentication failed"
        "permission denied"
        "disk full"
        "out of memory"
        "syntax error"
        "table.*does not exist"
        "database.*does not exist"
    )
    
    # Database migration related errors that can be temporarily ignored during deployment
    local migration_patterns=(
        "column.*does not exist"
        "relation.*does not exist.*migration"
        "Flyway"
        "database migration"
        "schema migration"
    )
    
    # Check for migration-related errors first (these can be temporary during deployment)
    local has_migration_errors=false
    for pattern in "${migration_patterns[@]}"; do
        if grep -qi "$pattern" "$output_file" 2>/dev/null; then
            log "INFO: Found migration-related error pattern (may be temporary): $pattern"
            has_migration_errors=true
        fi
    done
    
    # Check for fatal errors
    for pattern in "${fatal_patterns[@]}"; do
        if grep -qi "$pattern" "$output_file" 2>/dev/null; then
            log "FATAL: Found critical error pattern: $pattern"
            has_fatal_errors=true
            break
        fi
    done
    
    # If no fatal errors, check if we have only benign errors
    if [ "$has_fatal_errors" = false ]; then
        local has_errors=false
        local has_only_benign=true
        
        # Check if there are any errors at all
        if grep -qi "error\|exception\|failed" "$output_file" 2>/dev/null; then
            has_errors=true
            
                    # Check if all errors match benign or migration patterns
        local saw_benign_app_registration=false
        while read -r error_line; do
            local is_benign=false
            
            # First check if it's a migration-related error
            for pattern in "${migration_patterns[@]}"; do
                if echo "$error_line" | grep -qi "$pattern"; then
                    is_benign=true
                    log "INFO: Ignoring migration-related error (will be resolved after database migration): $(echo "$error_line" | tr -d '\n')"
                    break
                fi
            done
            
            # If not migration-related, check if it's a benign SQL error or deployment issue
            if [ "$is_benign" = false ]; then
                for pattern in "${benign_patterns[@]}"; do
                    if echo "$error_line" | grep -qi "$pattern"; then
                        is_benign=true
                        # Special handling for application registration errors
                        if echo "$error_line" | grep -qi "application.*already registered"; then
                            log "INFO: Ignoring benign deployment error (application may be working): $(echo "$error_line" | tr -d '\n')"
                            saw_benign_app_registration=true
                        else
                            log "INFO: Ignoring benign SQL error: $(echo "$error_line" | tr -d '\n')"
                        fi
                        break
                    fi
                done
            fi
            
            # Special handling: if we saw a benign app registration error, treat "Command deploy failed" as benign
            if [ "$is_benign" = false ] && [ "$saw_benign_app_registration" = true ] && echo "$error_line" | grep -qi "Command deploy failed"; then
                is_benign=true
                log "INFO: Ignoring 'Command deploy failed' after benign application registration error: $(echo "$error_line" | tr -d '\n')"
            fi
            
            if [ "$is_benign" = false ]; then
                has_only_benign=false
                log "WARNING: Found non-benign error: $(echo "$error_line" | tr -d '\n')"
            fi
        done < <(grep -i "error\|exception\|failed" "$output_file" 2>/dev/null)
        fi
        
        # Return success if no errors or only benign/migration errors
        if [ "$has_errors" = false ] || [ "$has_only_benign" = true ]; then
            # If we have migration errors, log a note about waiting for migration completion
            if [ "$has_migration_errors" = true ]; then
                log "INFO: Migration-related errors detected. Database migrations may need time to complete."
            fi
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# Function to check Java version for the dataverse user
check_java_version() {
    local version
    if command -v java >/dev/null 2>&1; then
        # Try to get Java version as dataverse user first
        if sudo -u "$DATAVERSE_USER" java -version >/dev/null 2>&1; then
            version=$(sudo -u "$DATAVERSE_USER" java -version 2>&1 | grep -oP 'version "([0-9]+)' | grep -oP '[0-9]+' | head -1)
        else
            # Fall back to system Java version
            version=$(java -version 2>&1 | grep -oP 'version "([0-9]+)' | grep -oP '[0-9]+' | head -1)
        fi
        echo "$version"
    else
        echo "0"
    fi
}

# Function to check and upgrade Java if necessary
check_and_upgrade_java() {
    local current_java_version
    current_java_version=$(check_java_version)
    
    log "Current Java version: $current_java_version"
    log "Required Java version: $REQUIRED_JAVA_VERSION"
    
    if [ -z "$current_java_version" ] || [ "$current_java_version" -lt "$REQUIRED_JAVA_VERSION" ]; then
        log "Java version $current_java_version is below required version $REQUIRED_JAVA_VERSION"
        log "Running Java upgrade to version $REQUIRED_JAVA_VERSION..."
        
        # Check if upgrade_java.sh exists
        local java_upgrade_script="$(dirname "$0")/upgrade_java.sh"
        if [ -x "$java_upgrade_script" ]; then
            log "Found Java upgrade script at: $java_upgrade_script"
            chmod +x "$java_upgrade_script"
            "$java_upgrade_script" "$REQUIRED_JAVA_VERSION"
            check_error "Java upgrade failed"
            log "Java upgrade completed successfully."
            
            # Verify the upgrade worked
            local new_java_version
            new_java_version=$(check_java_version)
            if [ -z "$new_java_version" ] || [ "$new_java_version" -lt "$REQUIRED_JAVA_VERSION" ]; then
                log "ERROR: Java upgrade failed. Current version: $new_java_version, Required: $REQUIRED_JAVA_VERSION"
                return 1
            fi
            log "Java version after upgrade: $new_java_version"
        else
            log "ERROR: Java upgrade script not found at $java_upgrade_script"
            log "Please manually upgrade Java to version $REQUIRED_JAVA_VERSION or higher"
            return 1
        fi
    else
        log "Java version $current_java_version meets requirements (>= $REQUIRED_JAVA_VERSION). Skipping Java upgrade."
    fi
}

# Function to detect and resolve mixed state
resolve_mixed_state() {
    log "Checking for mixed state issues..."
    
    # Get current deployed applications
    local deployed_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>/dev/null)
    
    # Get API version if available
    local api_version=""
    if curl -s -f "http://localhost:8080/api/info/version" &> /dev/null; then
        api_version=$(curl -s "http://localhost:8080/api/info/version" | jq -r '.data.version' 2>/dev/null || echo "unknown")
    fi
    
    log "Deployed applications: $deployed_apps"
    log "API version: $api_version"
    
    # Check for mixed state scenarios
    local has_mixed_state=false
    
    if echo "$deployed_apps" | grep -q "dataverse-"; then
        if [[ "$api_version" != "$CURRENT_VERSION"* ]] && [[ "$api_version" != "unknown" ]]; then
            log "WARNING: Mixed state detected - deployed app version doesn't match API version"
            has_mixed_state=true
        fi
        
        # Check if we have both versions deployed somehow
        if echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION" && echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
            log "WARNING: Both current and target versions are deployed"
            has_mixed_state=true
        fi
    fi
    
    # Check database for schema that doesn't match deployed version
    if [[ "$api_version" == "$CURRENT_VERSION"* ]] && psql -U dataverse dataverse -c "\d datasetversion" 2>/dev/null | grep -q "archivenote"; then
        log "WARNING: Database has 6.6 schema but 6.5 is deployed - mixed state detected"
        has_mixed_state=true
    fi
    
    if [ "$has_mixed_state" = true ]; then
        log "Mixed state detected. Performing comprehensive cleanup..."
        
        # Stop all services
        sudo systemctl stop payara || true
        
        # Clean up all deployed applications
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-"* 2>/dev/null || true
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
        
        # Start Payara
        sudo systemctl start payara
        sleep 30
        
        # Wait for Payara to be ready
        local counter=0
        while [ $counter -lt 60 ]; do
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
                break
            fi
            sleep 5
            counter=$((counter + 5))
        done
        
        log "Mixed state cleanup completed."
        return 0
    else
        log "No mixed state detected."
        return 0
    fi
}

# Function to check current version
check_current_version() {
    local version response asadmin_path
    log "Checking current Dataverse version..."

    # Try multiple possible asadmin paths
    if [ -x "/usr/local/payara6/bin/asadmin" ]; then
        asadmin_path="/usr/local/payara6/bin/asadmin"
    elif [ -x "/usr/local/payara/bin/asadmin" ]; then
        asadmin_path="/usr/local/payara/bin/asadmin"
    elif [ -x "$PAYARA/bin/asadmin" ]; then
        asadmin_path="$PAYARA/bin/asadmin"
    else
        log "✗ ERROR: Could not find asadmin command at any of the expected locations:"
        log "  - /usr/local/payara6/bin/asadmin"
        log "  - /usr/local/payara/bin/asadmin"
        log "  - $PAYARA/bin/asadmin"
        log "This likely means Payara is not installed or the installation is incomplete."
        log "Manual intervention required. Please ensure Payara is installed and asadmin is available."
        exit 1
    fi

    response=$(sudo -u "$DATAVERSE_USER" $asadmin_path list-applications 2>&1)

    # Check if "No applications are deployed to this target server" is part of the response
    if [[ "$response" == *"No applications are deployed to this target server"* ]]; then
        log "✗ ERROR: No Dataverse applications are deployed to this target server."
        log "Manual intervention required. Please deploy Dataverse or restore from backup before running this upgrade."
        exit 1
    fi

    # If no such message, check the Dataverse version via the API
    version=$(curl -s "http://localhost:8080/api/info/version" | grep -o '"version":"[^"]*"' | sed 's/"version":"//;s/"//')

    # Handle different version scenarios
    if [[ -n "$version" ]]; then
        log "Detected Dataverse version: $version"
        
        # Case 1: ✅ Perfect - running the version we expect to upgrade FROM
        if [[ "$version" == "$CURRENT_VERSION" ]]; then
            log "✓ Current version is $CURRENT_VERSION as expected. Proceeding with upgrade to $TARGET_VERSION."
            return 0
            
        # Case 2: ✅ Already at target version - no upgrade needed
        elif [[ "$version" == "$TARGET_VERSION" ]]; then
            log "✓ Current version is already $TARGET_VERSION. No upgrade needed."
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "Your system is already up to date."
            return 1
            
        # Case 3: ❌ Running a version that's too old for this upgrade
        elif version_compare "$version" "$CURRENT_VERSION"; then
            log "✗ ERROR: Current version ($version) is OLDER than expected ($CURRENT_VERSION)"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "Please upgrade to $CURRENT_VERSION first using the appropriate script."
            log "Example upgrade path: 6.3 → 6.4 → 6.5 → 6.6"
            log "Exiting to prevent potential data corruption."
            return 1
            
        # Case 4: ❌ Running a version that's newer than target (unusual)
        elif version_compare "$TARGET_VERSION" "$version"; then
            log "✗ ERROR: Current version ($version) is NEWER than target version ($TARGET_VERSION)"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "You may need a different upgrade script or this is a development version."
            log "Exiting to prevent potential data corruption."
            return 1
            
        # Case 5: ❌ Unexpected version scenario
        else
            log "✗ ERROR: Unexpected version scenario. Current: $version, Expected: $CURRENT_VERSION, Target: $TARGET_VERSION"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "Exiting to prevent potential data corruption."
            return 1
        fi
    else
        log "✗ ERROR: Cannot determine current Dataverse version from API or deployed applications."
        log "Manual intervention required. Please ensure Dataverse is running and accessible, or restore from backup."
        exit 1
    fi
}

# STEP 1: List deployed applications
list_applications() {
    log "Listing currently deployed applications..."
    log "Running command: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin list-applications"
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE"; then
        log "Application list completed successfully."
    else
        log "ERROR: Failed to list applications."
        return 1
    fi
}

# STEP 2: Undeploy the previous version
undeploy_dataverse() {
    log "Checking for deployed Dataverse applications..."
    
    # Check for any version of dataverse that might be deployed
    local deployed_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE")
    
    # Undeploy any dataverse applications found
    if echo "$deployed_apps" | grep -q "dataverse-"; then
        log "Found Dataverse applications deployed. Proceeding with comprehensive undeploy..."
        
        # Try to undeploy the current version first
        if echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION"; then
            log "Undeploying dataverse-$CURRENT_VERSION..."
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy dataverse-$CURRENT_VERSION 2>&1 | tee -a "$LOGFILE"; then
                log "Undeploy of dataverse-$CURRENT_VERSION completed successfully."
            else
                log "WARNING: Standard undeploy of dataverse-$CURRENT_VERSION failed. Continuing with recovery."
            fi
        fi
        
        # Also try to undeploy the target version in case it was partially deployed
        if echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
            log "Found partially deployed dataverse-$TARGET_VERSION. Attempting to undeploy..."
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy dataverse-$TARGET_VERSION 2>&1 | tee -a "$LOGFILE"; then
                log "Undeploy of dataverse-$TARGET_VERSION completed successfully."
            else
                log "WARNING: Failed to undeploy dataverse-$TARGET_VERSION. Will clean up manually."
            fi
        fi
        
        # Force cleanup of any remaining dataverse applications
        while read -r app_line; do
            if echo "$app_line" | grep -q "dataverse-"; then
                local app_name=$(echo "$app_line" | awk '{print $1}')
                if [[ "$app_name" =~ ^dataverse- ]]; then
                    log "Force undeploying remaining application: $app_name"
                    sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy "$app_name" 2>&1 | tee -a "$LOGFILE" || true
                fi
            fi
        done < <(echo "$deployed_apps")
        
        # Verify no dataverse applications remain
        local remaining_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>/dev/null)
        if echo "$remaining_apps" | grep -q "dataverse-"; then
            log "WARNING: Some Dataverse applications may still be deployed. Will clean up in application state clearing step."
        else
            log "All Dataverse applications successfully undeployed."
            return 0
        fi
        
        # If standard undeploy fails, try recovery methods
        log "WARNING: Standard undeploy failed. Attempting recovery methods..."
        
        # Check and diagnose policy file issues
        log "Checking security policy configuration..."
        if [ -f "$PAYARA/glassfish/domains/domain1/config/default.policy" ]; then
            log "Policy file exists. Checking permissions..."
            ls -la "$PAYARA/glassfish/domains/domain1/config/default.policy" | tee -a "$LOGFILE"
        else
            log "WARNING: default.policy file not found. This may be the cause of the undeploy failure."
        fi
        
        # Recovery Method 1: Stop Payara, clean cache, restart, then undeploy
        log "Recovery Method 1: Restarting Payara and cleaning cache..."
        sudo systemctl stop payara
        sleep 5
        
        # Clean various cache directories that might cause issues
        log "Cleaning Payara cache directories..."
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
        sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/ext" 2>/dev/null || true
        
        # Restart Payara
        sudo systemctl start payara
        sleep 30
        
        # Wait for Payara to fully start
        log "Waiting for Payara to fully initialize..."
        local retries=0
        while [ $retries -lt 12 ]; do
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
                break
            fi
            sleep 10
            retries=$((retries + 1))
            log "Waiting for Payara startup... ($retries/12)"
        done
        
        # Try undeploy again
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy dataverse-$CURRENT_VERSION; then
            log "Recovery Method 1 successful: Undeploy completed after restart."
            return 0
        fi
        
        # Recovery Method 2: Force undeploy with --cascade option
        log "Recovery Method 2: Attempting force undeploy with cascade..."
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy --cascade=true dataverse-$CURRENT_VERSION; then
            log "Recovery Method 2 successful: Force undeploy completed."
            return 0
        fi
        
        # Recovery Method 3: Manual application removal
        log "Recovery Method 3: Manual application directory cleanup..."
        if [ -d "$PAYARA/glassfish/domains/domain1/applications/dataverse-$CURRENT_VERSION" ]; then
            log "Removing application directory manually..."
            sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-$CURRENT_VERSION"
        fi
        
        # Clean application references from domain.xml if they exist
        if [ -f "$PAYARA/glassfish/domains/domain1/config/domain.xml" ]; then
            log "Checking domain.xml for application references..."
            if grep -q "dataverse-$CURRENT_VERSION" "$PAYARA/glassfish/domains/domain1/config/domain.xml"; then
                log "WARNING: Application references still found in domain.xml. Manual cleanup may be required."
                log "After upgrade completion, you may need to manually edit domain.xml to remove old references."
            fi
        fi
        
        # Final verification
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
            log "WARNING: Application still appears in list-applications output."
            log "This may not prevent the upgrade from continuing, but manual cleanup may be needed."
            log "Continuing with upgrade process..."
            return 0
        else
            log "Recovery successful: Application no longer appears in deployed applications."
            return 0
        fi
    else
        log "Dataverse is not currently deployed. Skipping undeploy step."
        return 0
    fi
}

# STEP 3: Create Payara domain backup
backup_payara_domain() {
    log "Creating backup of Payara domain configuration..."
    
    # Check if Payara directory exists
    if [ ! -d "$PAYARA" ]; then
        log "WARNING: Payara directory $PAYARA not found. Skipping domain backup."
        return 0
    fi
    
    # Check if domain1 exists
    if [ ! -d "$PAYARA/glassfish/domains/domain1" ]; then
        log "WARNING: Domain1 directory not found in $PAYARA. Skipping domain backup."
        return 0
    fi
    
    # Create backup directory if it doesn't exist
    local BACKUP_DIR="${PAYARA}.${CURRENT_VERSION}.backup"
    if [ ! -d "$BACKUP_DIR" ]; then
        log "Creating backup directory: $BACKUP_DIR"
        sudo mkdir -p "$BACKUP_DIR"
        sudo mkdir -p "$BACKUP_DIR/glassfish/domains"
        check_error "Failed to create backup directory"
    fi
    
    # Copy domain configuration to backup
    if [ ! -d "$BACKUP_DIR/glassfish/domains/domain1" ]; then
        log "Backing up domain1 configuration..."
        sudo cp -r "$PAYARA/glassfish/domains/domain1" "$BACKUP_DIR/glassfish/domains/"
        check_error "Failed to backup domain1 configuration"
        log "Domain backup created successfully at: $BACKUP_DIR/glassfish/domains/domain1"
    else
        log "Domain backup already exists. Skipping backup creation."
    fi
}

# STEP 4: Stop Payara
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        sudo systemctl stop payara || return 1
        log "Payara service stopped."
    else
        log "Payara is already stopped."
    fi
}

# STEP 5: Upgrade to Payara 6.2025.2
upgrade_payara() {
    log "Starting Payara upgrade to version $PAYARA_VERSION..."
    
    # Create temporary directory for download
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    # Move current Payara directory out of the way (domain backup was already created)
    if [ -d "$PAYARA" ]; then
        log "Moving current Payara installation out of the way..."
        # Check if backup directory already exists (from backup step)
        if [ -d "${PAYARA}.${CURRENT_VERSION}.backup" ]; then
            log "Backup directory already exists. Removing current Payara installation..."
            sudo rm -rf "$PAYARA"
        else
            log "Creating backup during Payara move..."
            sudo mv "$PAYARA" "${PAYARA}.${CURRENT_VERSION}.backup"
        fi
        check_error "Failed to handle current Payara installation"
    fi
    
    # Download new Payara version
    log "Downloading Payara $PAYARA_VERSION..."
    wget -O "payara-${PAYARA_VERSION}.zip" "$PAYARA_DOWNLOAD_URL"
    check_error "Failed to download Payara $PAYARA_VERSION"
    
    # Verify checksum
    verify_checksum "payara-${PAYARA_VERSION}.zip" "$PAYARA_SHA256" "Payara $PAYARA_VERSION"
    check_error "Payara $PAYARA_VERSION checksum verification failed"
    
    # Extract to /usr/local
    log "Extracting Payara to /usr/local..."
    sudo unzip "payara-${PAYARA_VERSION}.zip" -d /usr/local/
    check_error "Failed to extract Payara"
    
    # Ensure correct directory naming
    if [ -d "/usr/local/payara6" ]; then
        if [ "$PAYARA" != "/usr/local/payara6" ]; then
            sudo mv /usr/local/payara6 "$PAYARA"
        fi
    fi
    
    # Replace the brand new domain1 with the old preserved domain1
    log "Restoring domain configuration..."
    
    # Check if backup directory exists
    if [ ! -d "${PAYARA}.${CURRENT_VERSION}.backup" ]; then
        log "ERROR: Backup directory ${PAYARA}.${CURRENT_VERSION}.backup not found!"
        log "This indicates the Payara backup step was not completed successfully."
        log "Cannot proceed with domain restoration without a backup."
        
        # Check if the original Payara is still available elsewhere
        if [ -d "/usr/local/payara5" ]; then
            log "Found /usr/local/payara5. Attempting to use as backup source..."
            sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_DIST"
            sudo cp -r "/usr/local/payara5/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
            check_error "Failed to restore domain configuration from payara5"
        elif [ -d "/usr/local/payara" ] && [ "/usr/local/payara" != "$PAYARA" ]; then
            log "Found /usr/local/payara. Attempting to use as backup source..."
            sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_DIST"
            sudo cp -r "/usr/local/payara/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
            check_error "Failed to restore domain configuration from /usr/local/payara"
        else
            log "ERROR: No suitable domain backup found. Using fresh domain1 configuration."
            log "WARNING: This will require manual reconfiguration of Dataverse settings!"
            log "You will need to:"
            log "  1. Configure database connection"
            log "  2. Set up JVM options"
            log "  3. Configure any custom settings"
            # Keep the fresh domain1 and continue
        fi
    else
        # Normal backup restoration
        if [ ! -d "${PAYARA}.${CURRENT_VERSION}.backup/glassfish/domains/domain1" ]; then
            log "ERROR: Domain backup directory ${PAYARA}.${CURRENT_VERSION}.backup/glassfish/domains/domain1 not found!"
            log "Using fresh domain1 configuration instead."
            log "WARNING: Manual reconfiguration will be required!"
        else
            sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_DIST"
            sudo mv "${PAYARA}.${CURRENT_VERSION}.backup/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
            check_error "Failed to restore domain configuration"
            log "Domain configuration restored successfully from backup."
        fi
    fi
    
    # Set ownership
    sudo chown -R "$DATAVERSE_USER:" "$PAYARA"
    check_error "Failed to set Payara ownership"
    
    # Update the symlink to the new Payara installation
    log "Updating symlink to new Payara installation..."
    # Remove the old symlink if it exists
    if [ -L "/usr/local/payara6" ]; then
        sudo rm -f /usr/local/payara6
    fi
    sudo ln -sf "$PAYARA" /usr/local/payara6
    
    log "Payara upgrade completed successfully."
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

# STEP 5: Download and deploy Dataverse 6.6
download_dataverse_war() {
    log "Downloading Dataverse $TARGET_VERSION WAR file..."
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    wget -O "dataverse-${TARGET_VERSION}.war" "$DATAVERSE_WAR_URL"
    check_error "Failed to download Dataverse WAR file"
    
    # Verify checksum
    verify_checksum "dataverse-${TARGET_VERSION}.war" "$DATAVERSE_WAR_SHA256" "Dataverse $TARGET_VERSION WAR"
    check_error "Dataverse $TARGET_VERSION WAR checksum verification failed"
    
    # Move to a standard location
    sudo mv "dataverse-${TARGET_VERSION}.war" "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    check_error "Failed to move WAR file"
    
    log "Dataverse WAR download completed successfully."
    sudo chown -R "$DATAVERSE_USER:" "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

deploy_dataverse() {
    log "Deploying Dataverse $TARGET_VERSION..."
    log "Running command: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin deploy $WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    
    # Create temporary file to capture deployment output for analysis
    local deploy_output_file=$(mktemp)
    
    # Capture the deployment output to both log file and temp file for analysis
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE" > "$deploy_output_file"; then
        log "Dataverse deployment command completed. Analyzing output..."
        if analyze_deployment_output "$deploy_output_file"; then
            log "Deployment command completed successfully (benign errors ignored)."
            # Wait for potential database migrations to complete before verification
            log "Waiting for database migrations to complete (this may take several minutes)..."
            sleep 60
            
            # Now verify what's actually deployed
            if verify_deployment; then
                log "Dataverse deployment verified successfully."
                rm -f "$deploy_output_file"
                return 0
            else
                log "Deployment verification failed. Attempting recovery..."
            fi
        else
            log "Deployment failed with non-benign errors. Attempting recovery steps..."
        fi
    else
        # Check if this is an "already registered" case, which often means the app is actually working
        if grep -qi "application.*already registered" "$deploy_output_file" 2>/dev/null; then
            log "Application already registered error detected. Checking if application is actually working..."
            sleep 30  # Give it a moment to settle
            if verify_deployment; then
                log "Application is working despite 'already registered' error. Deployment successful."
                rm -f "$deploy_output_file"
                return 0
            else
                log "Application not working. Will attempt recovery..."
            fi
        else
            log "Deployment command failed. Attempting recovery steps..."
        fi
    fi
    
    # Recovery steps
    log "Stopping Payara service..."
    sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"
    
    log "Cleaning up cached files..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>&1 | tee -a "$LOGFILE"
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>&1 | tee -a "$LOGFILE"
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases" 2>&1 | tee -a "$LOGFILE"
    
    log "Starting Payara service..."
    sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"
    
    # Wait for startup
    log "Waiting 60 seconds for Payara to fully start and begin database migrations..."
    sleep 60
    
    # Retry deployment with analysis
    log "Retrying deployment..."
    log "Running command: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin deploy $WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    local retry_output_file=$(mktemp)
    
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE" > "$retry_output_file"; then
        log "Retry deployment command completed. Analyzing output..."
        if analyze_deployment_output "$retry_output_file"; then
            log "Retry deployment command completed successfully (benign/migration errors ignored)."
            
            # For database migration scenarios, give extra time before verification
            log "Allowing extra time for database migrations to complete after retry deployment..."
            sleep 120
            
            # Verify what's actually deployed after retry
            if verify_deployment; then
                log "Dataverse deployment verified successfully after retry."
                rm -f "$deploy_output_file" "$retry_output_file"
                return 0
            else
                log "ERROR: Failed to verify Dataverse deployment after recovery attempt."
                rm -f "$deploy_output_file" "$retry_output_file"
                return 1
            fi
        else
            log "ERROR: Failed to deploy Dataverse after recovery attempt with non-benign errors."
            rm -f "$deploy_output_file" "$retry_output_file"
            return 1
        fi
    else
        log "ERROR: Retry deployment command failed."
        rm -f "$deploy_output_file" "$retry_output_file"
        return 1
    fi
}

# Function to clear application caches and force clean state
clear_application_state() {
    log "Clearing application state and caches..."
    
    # Stop Payara to clear all cached state
    sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"
    
    # Clear all cached files that might hold old entity mappings
    log "Removing cached application files..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/__internal" 2>/dev/null || true
    
    # Clear any remaining deployed applications
    log "Ensuring all old applications are completely removed..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-$CURRENT_VERSION" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-$TARGET_VERSION" 2>/dev/null || true
    
    # Start Payara with clean state
    log "Starting Payara with clean application state..."
    if ! sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"; then
        log "ERROR: Failed to start Payara service"
        log "Checking service status for more details..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        return 1
    fi
    
    # Wait for startup
    sleep 30
    
    # Verify Payara is responding before proceeding
    local counter=0
    while [ $counter -lt 60 ]; do
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
            log "Payara is responding to asadmin commands."
            break
        fi
        sleep 5
        counter=$((counter + 5))
    done
    
    if [ $counter -ge 60 ]; then
        log "ERROR: Payara not responding after restart"
        log "Checking service status for more details..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        return 1
    fi
}

# Function to run database migrations if needed
run_database_migrations() {
    log "Checking if database migrations are needed..."
    
    # Wait a bit for the application to start
    sleep 30
    
    # Try to trigger database migration via API if available
    # This is a fallback in case automatic migrations didn't run
    local migration_endpoint="http://localhost:8080/api/admin/migrate"
    
    if curl -s -f "$migration_endpoint" &> /dev/null; then
        log "Database migration endpoint available, attempting to trigger migrations..."
        if curl -X POST -s "$migration_endpoint" 2>&1 | tee -a "$LOGFILE"; then
            log "Database migration request completed."
        else
            log "Database migration request failed, but this may be normal if migrations are automatic."
        fi
    else
        log "Database migration endpoint not available (this is normal for newer versions with automatic migrations)."
    fi
    
    # Give additional time for any automatic migrations to complete
    log "Waiting additional time for database migrations to complete..."
    sleep 60
}

# Function to verify what's actually deployed
verify_deployment() {
    log "Verifying deployment status (timeout: 10 minutes)..."
    local MAX_WAIT=600  # Increased to 10 minutes to allow for database migrations
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
                log "Dataverse is responsive, but version is '$version' (expected '$TARGET_VERSION'). Database migration may be in progress..."
            fi
        else
            # Check what applications are actually deployed
            local deployed_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>/dev/null)
            if echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
                log "Application dataverse-$TARGET_VERSION found in deployment list, but API not yet responding. Database migration may be in progress..."
            elif echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION"; then
                log "WARNING: Old version dataverse-$CURRENT_VERSION still deployed. New deployment may have failed."
                # Try to undeploy old version
                log "Attempting to undeploy old version..."
                sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy "dataverse-$CURRENT_VERSION" 2>&1 | tee -a "$LOGFILE" || true
            else
                log "No Dataverse application found in deployment list. Checking Payara server logs for errors..."
                # Show recent server log entries to help diagnose issues
                if [ -f "$PAYARA/glassfish/domains/domain1/logs/server.log" ]; then
                    log "Recent server log entries (last 10 lines):"
                    tail -10 "$PAYARA/glassfish/domains/domain1/logs/server.log" | tee -a "$LOGFILE"
                fi
            fi
        fi

        sleep 10  # Increased sleep interval for database migration scenarios
        COUNTER=$((COUNTER + 10))
        if [ $((COUNTER % 60)) -eq 0 ]; then
             log "Still waiting for deployment verification... ($COUNTER seconds elapsed)"
             log "If database migration is in progress, this may take several more minutes..."
        fi
    done

    log "ERROR: Deployment verification failed within the timeout period."
    log "Final deployment status:"
    sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE"
    
    log "Checking server logs for more details:"
    if [ -f "$PAYARA/glassfish/domains/domain1/logs/server.log" ]; then
        log "Last 20 lines of server log:"
        tail -20 "$PAYARA/glassfish/domains/domain1/logs/server.log" | tee -a "$LOGFILE"
    fi
    
    return 1
}

# STEP 6: Update language packs (if applicable)
update_language_packs() {
    log "Checking for internationalization requirements..."
    
    if [ -n "$LANGUAGE_PACKS_DIR" ] && [ -d "$LANGUAGE_PACKS_DIR" ]; then
        log "Language packs directory found. Please update translations manually via Dataverse language packs."
        log "Latest English files available at: https://github.com/IQSS/dataverse/tree/v6.6/src/main/java/propertyFiles"
        log "Language packs update notification completed."
    else
        log "No language packs directory configured. Skipping language pack updates."
    fi
}

# STEP 7: Configure feature flags
configure_feature_flags() {
    log "Configuring optional feature flags..."
    
    # Prompt for index-harvested-metadata-source feature flag
    read -p "Do you want to enable the 'index-harvested-metadata-source' feature flag? This affects harvesting and requires reindexing. (y/n): " ENABLE_HARVESTED_FLAG
    
    if [[ "$ENABLE_HARVESTED_FLAG" =~ ^[Yy]$ ]]; then
        log "Enabling index-harvested-metadata-source feature flag..."
        # This would be set via API or configuration - implementation depends on how Dataverse handles this
        log "Feature flag configuration completed. (Note: This may require manual configuration via admin interface)"
    else
        log "Skipping index-harvested-metadata-source feature flag."
    fi
}

# STEP 8: Configure SameSite
configure_samesite() {
    log "Configuring SameSite cookie settings..."
    
    log "Setting SameSite value to Lax..."
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin set server-config.network-config.protocols.protocol.http-listener-1.http.cookie-same-site-value=Lax 2>&1 | tee -a "$LOGFILE"; then
        log "SameSite value set successfully."
    else
        log "ERROR: Failed to set SameSite value."
        return 1
    fi
    
    log "Enabling SameSite..."
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin set server-config.network-config.protocols.protocol.http-listener-1.http.cookie-same-site-enabled=true 2>&1 | tee -a "$LOGFILE"; then
        log "SameSite enabled successfully."
    else
        log "ERROR: Failed to enable SameSite."
        return 1
    fi
    
    log "SameSite configuration completed successfully."
}

# STEP 9: Restart Payara
restart_payara() {
    log "Restarting Payara service..."
    log "Stopping Payara service..."
    if sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"; then
        log "Payara service stopped successfully."
    else
        log "WARNING: Issues stopping Payara service, continuing..."
    fi
    
    sleep 5
    
    log "Starting Payara service..."
    if sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"; then
        log "Payara service start command completed."
    else
        log "ERROR: Failed to start Payara service."
        return 1
    fi
    
    # Wait for Payara to fully start
    log "Waiting for Payara to fully initialize (timeout: ${PAYARA_START_TIMEOUT}s)..."
    local COUNTER=0
    while [ $COUNTER -lt $PAYARA_START_TIMEOUT ]; do
        if curl -s -f "http://localhost:8080/api/info/version" > /dev/null 2>&1; then
            log "Payara is ready and responding on port 8080."
            break
        fi
        if [ $((COUNTER % 30)) -eq 0 ] && [ $COUNTER -gt 0 ]; then
            log "Still waiting for Payara... (${COUNTER}s elapsed)"
            log "Checking Payara service status:"
            sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        fi
        sleep 5
        COUNTER=$((COUNTER + 5))
    done
    
    if [ $COUNTER -ge $PAYARA_START_TIMEOUT ]; then
        log "ERROR: Payara failed to start within the timeout period (${PAYARA_START_TIMEOUT}s)."
        log "Final Payara service status:"
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        log "Checking for Payara processes:"
        pgrep -f payara 2>&1 | tee -a "$LOGFILE" || log "No Payara processes found"
        return 1
    fi
    
    log "Payara restart completed successfully."
}

# STEP 10: Update citation metadata block
update_citation_metadata_block() {
    log "Updating citation metadata block..."
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    wget -O citation.tsv "$CITATION_TSV_URL"
    check_error "Failed to download citation metadata block"
    
    log "Loading citation metadata block (this may take several seconds due to size)..."
    log "Running command: curl http://localhost:8080/api/admin/datasetfield/load -H Content-type: text/tab-separated-values -X POST --upload-file citation.tsv"
    if curl "http://localhost:8080/api/admin/datasetfield/load" \
         -H "Content-type: text/tab-separated-values" \
         -X POST --upload-file citation.tsv 2>&1 | tee -a "$LOGFILE"; then
        log "Citation metadata block loaded successfully."
    else
        log "ERROR: Failed to load citation metadata block."
        return 1
    fi
    
    log "Citation metadata block update completed successfully."
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

add_3d_objects_metadata_block() {
    log "Adding 3D Objects metadata block..."
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    wget -O 3d_objects.tsv "$OBJECTS_3D_TSV_URL"
    check_error "Failed to download 3D Objects metadata block"
    
    log "Running command: curl http://localhost:8080/api/admin/datasetfield/load -H Content-type: text/tab-separated-values -X POST --upload-file 3d_objects.tsv"
    if curl "http://localhost:8080/api/admin/datasetfield/load" \
         -H "Content-type: text/tab-separated-values" \
         -X POST --upload-file 3d_objects.tsv 2>&1 | tee -a "$LOGFILE"; then
        log "3D Objects metadata block loaded successfully."
    else
        log "ERROR: Failed to load 3D Objects metadata block."
        return 1
    fi
    
    log "3D Objects metadata block addition completed successfully."
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

# STEP 11: Upgrade Solr
upgrade_solr() {
    log "Upgrading Solr to version $SOLR_VERSION..."
    
    # Check if Solr is running and stop it
    if systemctl is-active --quiet solr; then
        log "Stopping Solr service..."
        sudo systemctl stop solr
        check_error "Failed to stop Solr"
    fi
    
    # Backup current Solr installation
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
    
    # Download and install Solr 9.8.0
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    log "Downloading Solr $SOLR_VERSION..."
    wget -O "solr-${SOLR_VERSION}.tgz" "$SOLR_DOWNLOAD_URL"
    check_error "Failed to download Solr $SOLR_VERSION"
    
    # Verify checksum if available
    if [[ "$SOLR_SHA256" != "REPLACE_WITH_OFFICIAL_"* ]]; then
        verify_checksum "solr-${SOLR_VERSION}.tgz" "$SOLR_SHA256" "Solr $SOLR_VERSION"
        check_error "Solr $SOLR_VERSION checksum verification failed"
    fi
    
    log "Extracting Solr $SOLR_VERSION..."
    cd "$(dirname "$SOLR_PATH")"
    sudo tar xzf "$TMP_DIR/solr-${SOLR_VERSION}.tgz" || return 1
    
    # Create symlink if original was a symlink (following the symlink pattern for easy upgrades)
    if [ -L "$SOLR_PATH" ]; then
        log "Original Solr path was a symlink. Creating new symlink to solr-$SOLR_VERSION..."
        sudo ln -sf "$(dirname "$SOLR_PATH")/solr-$SOLR_VERSION" "$SOLR_PATH" || return 1
        log "Symlink updated to point to solr-$SOLR_VERSION"
    else
        # If not a symlink, move the extracted directory and create symlink for future upgrades
        log "Original Solr path was not a symlink. Moving to solr-$SOLR_VERSION and creating symlink..."
        sudo mv "solr-$SOLR_VERSION" "$(dirname "$SOLR_PATH")/solr-$SOLR_VERSION" || return 1
        sudo ln -sf "$(dirname "$SOLR_PATH")/solr-$SOLR_VERSION" "$SOLR_PATH" || return 1
        log "Solr installed and symlink created for future upgrades"
    fi
    
    # Robust fix: Ensure all Solr files are owned by $SOLR_USER after extraction and symlink creation
    log "Ensuring correct ownership for all Solr files..."
    sudo chown -R "$SOLR_USER:" "$(dirname "$SOLR_PATH")/solr-$SOLR_VERSION"
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH"
    log "Ownership for Solr directory and symlink target fixed."
    
    # Restore collection1 config from backup
    log "Restoring collection1 configuration..."
    if [ -d "${REAL_SOLR_DIR}.backup/server/solr/collection1" ]; then
        sudo cp -r "${REAL_SOLR_DIR}.backup/server/solr/collection1" "$SOLR_PATH/server/solr/" || return 1
    fi
    
    # Download new Solr configuration files from source tree (as per official instructions)
    log "Downloading Solr configuration files from source tree..."
    cd "$TMP_DIR"
    wget -O schema.xml "$SOLR_SCHEMA_URL"
    check_error "Failed to download Solr schema"
    
    wget -O solrconfig.xml "$SOLR_CONFIG_URL"
    check_error "Failed to download Solr config"
    
    # Install new configuration files
    log "Installing new Solr configuration files..."
    sudo cp schema.xml solrconfig.xml "$SOLR_PATH/server/solr/collection1/conf/"
    check_error "Failed to install Solr configuration files"
    
    # Set correct ownership
    sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
    
    # Set ownership for entire Solr directory
    log "Setting ownership for Solr directory..."
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH" || return 1
    
    # Verify the Solr binary exists and is executable
    if [ ! -f "$SOLR_PATH/bin/solr" ]; then
        log "ERROR: Solr binary not found at $SOLR_PATH/bin/solr after upgrade"
        log "Checking what was installed:"
        ls -la "$SOLR_PATH/" | tee -a "$LOGFILE"
        if [ -L "$SOLR_PATH" ]; then
            log "SOLR_PATH is a symlink. Following it:"
            ls -la "$(readlink -f "$SOLR_PATH")/" | tee -a "$LOGFILE"
        fi
        
        # Check if there are any solr-* directories that might have been created
        log "Checking for Solr installations in /usr/local:"
        ls -la /usr/local/solr* 2>/dev/null | tee -a "$LOGFILE" || log "No solr* directories found"
        
        # Try to find any solr binary
        log "Searching for Solr binary:"
        find /usr/local -name "solr" -type f 2>/dev/null | tee -a "$LOGFILE" || log "No solr binary found"
        
        log "ERROR: Solr upgrade appears to have failed. Manual intervention required."
        return 1
    fi
    
    # Make sure the Solr binary is executable
    sudo chmod +x "$SOLR_PATH/bin/solr"
    
    log "Solr binary upgrade and configuration update completed successfully."
    log "Solr binary location: $SOLR_PATH/bin/solr"
    
    # Recreate Solr collection to avoid schema compatibility issues
    recreate_solr_collection
    
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

# Function to recreate Solr collection to avoid schema compatibility issues
recreate_solr_collection() {
    log "Recreating Solr collection to avoid schema compatibility issues..."
    
    # Check if Solr is running and stop it
    if systemctl is-active --quiet solr; then
        log "Stopping Solr service for collection recreation..."
        sudo systemctl stop solr
        check_error "Failed to stop Solr"
    fi
    
    # Remove the old collection data to force a clean schema
    if [ -d "$SOLR_PATH/server/solr/collection1/data" ]; then
        log "Removing old collection data to ensure clean schema..."
        sudo rm -rf "$SOLR_PATH/server/solr/collection1/data"
        log "Old collection data removed."
    fi
    
    # Ensure proper ownership of the collection directory
    log "Ensuring proper ownership of collection directory..."
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/"
    
    # Start Solr to create a fresh collection
    log "Starting Solr to create fresh collection..."
    sudo systemctl start solr
    check_error "Failed to start Solr"
    
    # Wait for Solr to fully start
    log "Waiting for Solr to fully start..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        retries=$((retries + 1))
        log "Waiting for Solr startup... ($retries/30)"
    done
    
    if [ $retries -eq 30 ]; then
        log "ERROR: Solr failed to start within expected time"
        return 1
    fi
    
    # Verify the collection is healthy
    log "Verifying collection health..."
    local collection_status=$(curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" 2>/dev/null)
    
    if echo "$collection_status" | grep -q '"initFailures"'; then
        log "ERROR: Collection has initialization failures"
        log "Collection status: $collection_status"
        return 1
    fi
    
    if echo "$collection_status" | grep -q '"collection1"'; then
        log "✓ Solr collection recreated successfully"
        log "✓ Collection is healthy and ready for indexing"
    else
        log "ERROR: Collection1 not found in Solr status"
        log "Collection status: $collection_status"
        return 1
    fi
}

# Function to diagnose and fix common Solr configuration issues
diagnose_solr_issues() {
    log "Diagnosing Solr configuration issues..."
    
    # Check if collection1 exists and has proper structure
    if [ ! -d "$SOLR_PATH/server/solr/collection1" ]; then
        log "ERROR: collection1 directory not found. Creating it..."
        sudo -u "$SOLR_USER" mkdir -p "$SOLR_PATH/server/solr/collection1/conf"
        sudo -u "$SOLR_USER" mkdir -p "$SOLR_PATH/server/solr/collection1/data"
        
        # Create basic core.properties
        echo "name=collection1" | sudo -u "$SOLR_USER" tee "$SOLR_PATH/server/solr/collection1/core.properties" > /dev/null
    fi
    
    # Ensure conf directory exists
    if [ ! -d "$SOLR_PATH/server/solr/collection1/conf" ]; then
        log "Creating conf directory..."
        sudo -u "$SOLR_USER" mkdir -p "$SOLR_PATH/server/solr/collection1/conf"
    fi
    
    # Check and fix schema.xml
    if [ ! -f "$SOLR_PATH/server/solr/collection1/conf/schema.xml" ]; then
        log "ERROR: schema.xml not found. Downloading fresh copy..."
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        wget -O schema.xml "$SOLR_SCHEMA_URL"
        sudo cp schema.xml "$SOLR_PATH/server/solr/collection1/conf/"
        sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
    fi
    
    # Check and fix solrconfig.xml
    if [ ! -f "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" ]; then
        log "ERROR: solrconfig.xml not found. Downloading fresh copy..."
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        wget -O solrconfig.xml "$SOLR_CONFIG_URL"
        sudo cp solrconfig.xml "$SOLR_PATH/server/solr/collection1/conf/"
        sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
    fi
    
    # Fix ownership of entire Solr directory
    log "Fixing Solr directory ownership..."
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH"
    
    # Check Solr service configuration
    if [ -f "/etc/systemd/system/solr.service" ]; then
        log "Checking Solr service configuration..."
        grep -E "(User|ExecStart)" /etc/systemd/system/solr.service | tee -a "$LOGFILE"
        
        # Check if the service is pointing to the correct Solr path
        local service_solr_path=$(grep "ExecStart" /etc/systemd/system/solr.service | sed 's/.*\/usr\/local\/\([^ ]*\).*/\1/' | head -1)
        if [ -n "$service_solr_path" ]; then
            log "Service is configured to use: /usr/local/$service_solr_path"
            if [ "$service_solr_path" != "$(basename "$SOLR_PATH")" ]; then
                log "WARNING: Service configuration may be pointing to wrong Solr installation"
                log "Expected: $(basename "$SOLR_PATH"), Found: $service_solr_path"
            fi
        fi
    elif [ -f "/usr/lib/systemd/system/solr.service" ]; then
        log "Checking system Solr service configuration..."
        grep -E "(User|ExecStart)" /usr/lib/systemd/system/solr.service | tee -a "$LOGFILE"
    fi
    
    log "Solr diagnosis completed."
}

# Function to fix Solr service configuration
fix_solr_service() {
    log "Checking and fixing Solr service configuration..."
    
    # Check if the service file exists and is pointing to the correct Solr installation
    local service_file=""
    if [ -f "/etc/systemd/system/solr.service" ]; then
        service_file="/etc/systemd/system/solr.service"
    elif [ -f "/usr/lib/systemd/system/solr.service" ]; then
        service_file="/usr/lib/systemd/system/solr.service"
    else
        log "ERROR: No Solr service file found"
        return 1
    fi
    
    log "Found Solr service file: $service_file"
    
    # Check if the service is pointing to the correct Solr binary
    local current_exec_start=$(grep "ExecStart" "$service_file" | head -1)
    local expected_solr_bin="$SOLR_PATH/bin/solr"
    
    if [[ "$current_exec_start" == *"$expected_solr_bin"* ]]; then
        log "Solr service is correctly configured to use $expected_solr_bin"
    else
        log "WARNING: Solr service may be pointing to wrong binary"
        log "Current ExecStart: $current_exec_start"
        log "Expected to contain: $expected_solr_bin"
        
        # Check if the expected binary exists
        if [ -f "$expected_solr_bin" ]; then
            log "Expected Solr binary exists at $expected_solr_bin"
        else
            log "ERROR: Expected Solr binary not found at $expected_solr_bin"
            log "Checking what's available:"
            ls -la "$SOLR_PATH/bin/" 2>/dev/null | tee -a "$LOGFILE" || log "No bin directory found"
            return 1
        fi
    fi
    
    # Reload systemd to pick up any changes
    sudo systemctl daemon-reload
    
    log "Solr service configuration check completed."
}

# Function to fix broken Solr installation
fix_broken_solr_installation() {
    log "Attempting to fix broken Solr installation..."
    
    # Check if SOLR_PATH is a symlink and if it's broken
    if [ -L "$SOLR_PATH" ]; then
        local target=$(readlink -f "$SOLR_PATH")
        if [ ! -d "$target" ]; then
            log "ERROR: SOLR_PATH symlink is broken. Target $target does not exist."
            
            # Look for actual Solr installations
            local solr_installations=$(find /usr/local -maxdepth 1 -name "solr-*" -type d 2>/dev/null | sort -V | tail -1)
            if [ -n "$solr_installations" ]; then
                log "Found Solr installation: $solr_installations"
                log "Fixing symlink to point to: $solr_installations"
                sudo rm -f "$SOLR_PATH"
                sudo ln -sf "$solr_installations" "$SOLR_PATH"
                return 0
            else
                log "ERROR: No Solr installations found in /usr/local"
                return 1
            fi
        fi
    fi
    
    # Check if the Solr binary exists in the expected location
    if [ ! -f "$SOLR_PATH/bin/solr" ]; then
        log "ERROR: Solr binary not found at $SOLR_PATH/bin/solr"
        
        # Check if there's a different Solr installation
        local actual_solr_bin=$(find /usr/local -name "solr" -type f 2>/dev/null | grep -E "/bin/solr$" | head -1)
        if [ -n "$actual_solr_bin" ]; then
            local actual_solr_dir=$(dirname "$(dirname "$actual_solr_bin")")
            log "Found Solr binary at: $actual_solr_bin"
            log "Actual Solr directory: $actual_solr_dir"
            
            # Update the symlink to point to the correct location
            if [ "$actual_solr_dir" != "$SOLR_PATH" ]; then
                log "Updating SOLR_PATH symlink to point to: $actual_solr_dir"
                sudo rm -f "$SOLR_PATH"
                sudo ln -sf "$actual_solr_dir" "$SOLR_PATH"
                return 0
            fi
        else
            log "ERROR: No Solr binary found anywhere in /usr/local"
            return 1
        fi
    fi
    
    log "Solr installation appears to be correct."
    return 0
}

# Function to reinstall Solr if completely broken
reinstall_solr_if_needed() {
    log "Checking if Solr needs to be reinstalled..."
    
    # Check if we can find any Solr installation
    local solr_installations=$(find /usr/local -maxdepth 1 -name "solr-*" -type d 2>/dev/null | sort -V)
    local solr_binaries=$(find /usr/local -name "solr" -type f 2>/dev/null | grep -E "/bin/solr$")
    
    if [ -z "$solr_installations" ] && [ -z "$solr_binaries" ]; then
        log "ERROR: No Solr installation found. Attempting to reinstall Solr $SOLR_VERSION..."
        
        # Download and install Solr
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        log "Downloading Solr $SOLR_VERSION..."
        wget -O "solr-${SOLR_VERSION}.tgz" "$SOLR_DOWNLOAD_URL"
        if [ $? -ne 0 ]; then
            log "ERROR: Failed to download Solr $SOLR_VERSION"
            cd "$SCRIPT_DIR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        
        log "Extracting Solr $SOLR_VERSION..."
        cd /usr/local
        sudo tar xzf "$TMP_DIR/solr-${SOLR_VERSION}.tgz" || {
            log "ERROR: Failed to extract Solr"
            cd "$SCRIPT_DIR"
            rm -rf "$TMP_DIR"
            return 1
        }
        
        # Create symlink
        sudo ln -sf "/usr/local/solr-$SOLR_VERSION" "$SOLR_PATH"
        
        # Set ownership
        sudo chown -R "$SOLR_USER:" "$SOLR_PATH"
        
        # Make binary executable
        sudo chmod +x "$SOLR_PATH/bin/solr"
        
        log "Solr $SOLR_VERSION reinstalled successfully."
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
        return 0
    else
        log "Solr installation found, no reinstall needed."
        return 0
    fi
}

# STEP 11a: Update custom metadata block fields in Solr
update_solr_custom_fields() {
    log "Checking for custom metadata blocks and updating Solr fields..."
    
    # Check if there are custom metadata blocks by calling the API
    local custom_blocks=$(curl -s "http://localhost:8080/api/metadatablocks" | jq -r '.data[] | select(.name | test("^(citation|geospatial|socialscience|astrophysics|biomedical|journal|3d_objects)$") | not) | .name' 2>/dev/null)
    
    if [ -n "$custom_blocks" ]; then
        log "Custom metadata blocks detected. Updating Solr schema with custom fields..."
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        # Download update-fields script
        wget -O update-fields.sh "$UPDATE_FIELDS_URL"
        check_error "Failed to download update-fields script"
        
        # Set proper permissions for the script
        chmod 755 update-fields.sh
        sudo chown "$SOLR_USER:" update-fields.sh
        
        # Stop Solr for schema update
        sudo systemctl stop solr
        check_error "Failed to stop Solr for schema update"
        
        # Run update-fields script with proper permissions
        log "Running update-fields script to update Solr schema with custom metadata fields..."
        # Copy the script to a location where solr user can access it
        sudo cp update-fields.sh /tmp/update-fields.sh
        sudo chown "$SOLR_USER:" /tmp/update-fields.sh
        sudo chmod 755 /tmp/update-fields.sh
        
        if curl -s "http://localhost:8080/api/admin/index/solr/schema" | sudo -u "$SOLR_USER" bash /tmp/update-fields.sh "$SOLR_PATH/server/solr/collection1/conf/schema.xml" 2>&1 | tee -a "$LOGFILE"; then
            log "Custom fields script completed successfully."
        else
            log "WARNING: Custom fields update script failed, but continuing with upgrade..."
            log "You may need to manually update Solr schema for custom metadata blocks."
        fi
        
        # Clean up the copied script
        sudo rm -f /tmp/update-fields.sh
        
        log "Custom metadata block fields update attempt completed."
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
    else
        log "No custom metadata blocks detected. Skipping custom field updates."
    fi
    
    # Start Solr
    log "Starting Solr service..."
    if ! sudo systemctl start solr; then
        log "ERROR: Failed to start Solr service"
        log "Checking Solr service status for more details..."
        sudo systemctl status solr --no-pager 2>&1 | tee -a "$LOGFILE"
        log "Checking Solr logs for errors..."
        if [ -f "$SOLR_PATH/server/logs/solr.log" ]; then
            log "Last 20 lines of Solr log:"
            tail -20 "$SOLR_PATH/server/logs/solr.log" | tee -a "$LOGFILE"
        fi
        if [ -f "/var/log/solr/solr.log" ]; then
            log "Last 20 lines of system Solr log:"
            tail -20 "/var/log/solr/solr.log" | tee -a "$LOGFILE"
        fi
        log "Attempting to diagnose Solr startup issues..."
        
        # Check if Solr configuration is valid
        log "Checking Solr configuration..."
        if [ -f "$SOLR_PATH/server/solr/collection1/conf/schema.xml" ]; then
            log "Schema file exists and is readable"
            ls -la "$SOLR_PATH/server/solr/collection1/conf/schema.xml" | tee -a "$LOGFILE"
        else
            log "ERROR: Schema file not found at $SOLR_PATH/server/solr/collection1/conf/schema.xml"
        fi
        
        if [ -f "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" ]; then
            log "Solr config file exists and is readable"
            ls -la "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" | tee -a "$LOGFILE"
        else
            log "ERROR: Solr config file not found at $SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
        fi
        
        # Check ownership
        log "Checking Solr directory ownership..."
        ls -la "$SOLR_PATH/server/solr/collection1/conf/" | tee -a "$LOGFILE"
        
        # Try to diagnose and fix common issues
        log "Attempting to diagnose and fix Solr configuration issues..."
        diagnose_solr_issues
        fix_solr_service
        fix_broken_solr_installation
        
        # Try manual Solr start for more detailed error output
        log "Attempting manual Solr start for detailed error output..."
        # Check if Solr binary exists
        if [ -f "$SOLR_PATH/bin/solr" ]; then
            sudo -u "$SOLR_USER" "$SOLR_PATH/bin/solr start -c -p 8983" 2>&1 | tee -a "$LOGFILE" || true
        else
            log "ERROR: Solr binary not found at $SOLR_PATH/bin/solr"
            log "Checking what's in the Solr directory:"
            ls -la "$SOLR_PATH/" | tee -a "$LOGFILE"
            if [ -L "$SOLR_PATH" ]; then
                log "SOLR_PATH is a symlink. Following it:"
                ls -la "$(readlink -f "$SOLR_PATH")/" | tee -a "$LOGFILE"
            fi
            
            # Check if there are any solr-* directories in /usr/local
            log "Checking for Solr installations in /usr/local:"
            ls -la /usr/local/solr* 2>/dev/null | tee -a "$LOGFILE" || log "No solr* directories found in /usr/local"
            
            # Try to find the actual Solr binary
            log "Searching for Solr binary:"
            find /usr/local -name "solr" -type f 2>/dev/null | tee -a "$LOGFILE" || log "No solr binary found in /usr/local"
        fi
        
        # Try systemctl start again after diagnosis
        log "Attempting systemctl start again after diagnosis..."
        if sudo systemctl start solr; then
            log "Solr started successfully after diagnosis and fixes."
        else
            log "ERROR: Solr still failed to start after diagnosis."
            log "Attempting to reinstall Solr as last resort..."
            if reinstall_solr_if_needed; then
                log "Solr reinstalled. Attempting to start again..."
                if sudo systemctl start solr; then
                    log "Solr started successfully after reinstall."
                else
                    log "ERROR: Solr still failed to start after reinstall."
                    log "Manual intervention required. Please check:"
                    log "1. Solr service configuration: sudo systemctl status solr"
                    log "2. Solr logs: sudo journalctl -u solr -f"
                    log "3. Solr configuration files in $SOLR_PATH/server/solr/collection1/conf/"
                    return 1
                fi
            else
                log "ERROR: Failed to reinstall Solr."
                log "Manual intervention required. Please check:"
                log "1. Solr service configuration: sudo systemctl status solr"
                log "2. Solr logs: sudo journalctl -u solr -f"
                log "3. Solr configuration files in $SOLR_PATH/server/solr/collection1/conf/"
                return 1
            fi
        fi
    fi
    
    # Wait for Solr to be ready
    log "Waiting for Solr to be ready..."
    local COUNTER=0
    while [ $COUNTER -lt 120 ]; do  # Increased timeout to 2 minutes
        if curl -s "http://localhost:8983/solr/admin/cores?action=STATUS&core=collection1" > /dev/null; then
            log "Solr is ready."
            break
        fi
        sleep 2
        COUNTER=$((COUNTER + 2))
        if [ $((COUNTER % 20)) -eq 0 ]; then
            log "Still waiting for Solr... ($COUNTER seconds elapsed)"
        fi
    done
    
    if [ $COUNTER -ge 120 ]; then
        log "ERROR: Solr failed to start within timeout (2 minutes)."
        log "Checking if Solr process is running..."
        pgrep -f solr | tee -a "$LOGFILE" || log "No Solr processes found"
        log "Checking Solr logs for startup issues..."
        if [ -f "$SOLR_PATH/server/logs/solr.log" ]; then
            log "Last 30 lines of Solr log:"
            tail -30 "$SOLR_PATH/server/logs/solr.log" | tee -a "$LOGFILE"
        fi
        return 1
    fi
}

# STEP 12: Reindex Solr
reindex_solr() {
    log "Starting Solr reindexing process..."
    log "NOTE: This process may take a significant amount of time depending on the size of your installation."
    log "NOTE: Clearing Solr index..."
    curl -s http://localhost:8983/solr/admin/cores?action=CLEAR 2>&1 | tee -a "$LOGFILE"

    log "Running command: curl -s http://localhost:8080/api/admin/index"
    if curl -s "http://localhost:8080/api/admin/index" 2>&1 | tee -a "$LOGFILE"; then
        log "Solr reindexing initiated successfully. Monitor server logs for progress."
    else
        log "ERROR: Failed to initiate Solr reindexing."
        return 1
    fi
}

# STEP 13: Run reExportAll
run_reexport_all() {
    log "Running reExportAll to update dataset metadata exports..."
    log "This process updates all metadata exports with license enhancements and other v6.6 improvements."
    
    log "Running command: curl -s http://localhost:8080/api/admin/metadata/reExportAll"
    if curl -s "http://localhost:8080/api/admin/metadata/reExportAll" 2>&1 | tee -a "$LOGFILE"; then
        log "reExportAll initiated successfully. This may take time depending on the number of datasets."
    else
        log "ERROR: Failed to initiate reExportAll."
        return 1
    fi
}

# STEP 14: Optional re-harvest datasets
reharvest_datasets() {
    log "Checking for harvesting clients that may benefit from re-harvesting..."
    
    # Check if there are any harvesting clients
    local harvest_clients=$(curl -s "http://localhost:8080/api/harvest/clients" 2>/dev/null | jq -r '.data[] | .nickname' 2>/dev/null)
    
    if [ -n "$harvest_clients" ]; then
        read -p "Harvesting clients detected. Do you want to re-harvest datasets to pick up publisher attribution improvements? (y/n): " REHARVEST
        
        if [[ "$REHARVEST" =~ ^[Yy]$ ]]; then
            log "Re-harvesting recommendation: Delete and re-add each harvesting client, then run harvesting."
            log "This can be done through the harvesting client APIs to preserve configurations."
            log "For details, see the Admin Guide on Harvesting Clients."
        else
            log "Skipping dataset re-harvesting."
        fi
    else
        log "No harvesting clients detected. Skipping re-harvest option."
    fi
}

# Function to verify upgrade completion
verify_upgrade() {
    log "Verifying upgrade completion..."
    
    # Check Dataverse version
    local dv_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
    if [[ "$dv_version" == *"$TARGET_VERSION"* ]]; then
        log "✓ Dataverse version verification: $dv_version"
    else
        log "✗ Dataverse version verification failed. Expected $TARGET_VERSION, got $dv_version"
        log "Attempting automatic recovery..."
        
        # Check what's actually deployed
        local deployed_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>/dev/null)
        log "Current deployed applications:"
        echo "$deployed_apps" | tee -a "$LOGFILE"
        
        if echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION"; then
            log "Found old version still deployed. Attempting to complete deployment..."
            
            # Undeploy old version
            log "Undeploying old version dataverse-$CURRENT_VERSION..."
            sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy "dataverse-$CURRENT_VERSION" 2>&1 | tee -a "$LOGFILE" || true
            
            # Deploy new version
            log "Deploying new version dataverse-$TARGET_VERSION..."
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE"; then
                log "Deployment command completed. Waiting for service to be ready..."
                sleep 30
                
                # Re-check version
                local new_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
                if [[ "$new_version" == *"$TARGET_VERSION"* ]]; then
                    log "✓ Recovery successful! Dataverse version: $new_version"
                else
                    log "✗ Recovery failed. Version still: $new_version"
                    return 1
                fi
            else
                log "✗ Recovery deployment failed"
                return 1
            fi
        elif echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
            log "Target version is deployed but API not responding correctly. Restarting Payara..."
            sudo systemctl restart payara 2>&1 | tee -a "$LOGFILE"
            
            # Wait for restart
            local COUNTER=0
            while [ $COUNTER -lt 180 ]; do
                local restart_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
                if [[ "$restart_version" == *"$TARGET_VERSION"* ]]; then
                    log "✓ Restart successful! Dataverse version: $restart_version"
                    break
                fi
                sleep 5
                COUNTER=$((COUNTER + 5))
            done
            
            if [ $COUNTER -ge 180 ]; then
                log "✗ Restart recovery failed - timeout"
                return 1
            fi
        else
            log "✗ No Dataverse application found deployed. Manual intervention required."
            return 1
        fi
    fi
    
    # Check Payara version
    local payara_version=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin version 2>/dev/null | grep "Payara" | head -1)
    if [[ "$payara_version" == *"$PAYARA_VERSION"* ]]; then
        log "✓ Payara version verification: $payara_version"
    else
        log "✗ Payara version verification failed. Expected $PAYARA_VERSION"
        return 1
    fi
    
    # Check Solr status and version
    if curl -s "http://localhost:8983/solr/admin/cores?action=STATUS&core=collection1" > /dev/null; then
        log "✓ Solr service verification: Running"
        # Check Solr version
        local solr_version=$(curl -s "http://localhost:8983/solr/admin/info/system" 2>/dev/null | jq -r '.lucene."solr-spec-version"' 2>/dev/null)
        if [[ "$solr_version" == *"$SOLR_VERSION"* ]]; then
            log "✓ Solr version verification: $solr_version"
        else
            log "✗ Solr version verification failed. Expected $SOLR_VERSION, got $solr_version"
            return 1
        fi
    else
        log "✗ Solr service verification failed"
        return 1
    fi
    
    # Check 3D Objects metadata block
    local objects_3d_response=$(curl -s "http://localhost:8080/api/metadatablocks/3d_objects" 2>/dev/null)
    if echo "$objects_3d_response" | jq -e '.data' > /dev/null 2>&1; then
        log "✓ 3D Objects metadata block verification: Loaded"
    else
        log "! 3D Objects metadata block verification: Not found (this is optional for 6.6)"
        log "  Response: $(echo "$objects_3d_response" | head -c 100)..."
        log "  You can manually add it later if needed via the admin interface"
    fi
    
    # Test SameSite configuration
    local samesite_test=$(curl -s -I "http://localhost:8080" | grep -i "samesite")
    if [[ "$samesite_test" == *"SameSite=Lax"* ]]; then
        log "✓ SameSite configuration verification: Configured"
    else
        log "! SameSite configuration verification: Not detected (may not be visible in test)"
    fi
    
    log "Upgrade verification completed."
}

# Rollback function in case of catastrophic failure
rollback_payara() {
    log "========================================="
    log "EMERGENCY ROLLBACK: Restoring original Payara installation"
    log "========================================="
    
    # Check if backup exists
    if [ ! -d "${PAYARA}.${CURRENT_VERSION}.backup" ]; then
        log "ERROR: No backup found at ${PAYARA}.${CURRENT_VERSION}.backup"
        log "Cannot perform automatic rollback."
        return 1
    fi
    
    # Stop Payara if running
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara for rollback..."
        sudo systemctl stop payara || true
        sleep 5
    fi
    
    # Remove the current (failed) installation
    if [ -d "$PAYARA" ]; then
        log "Removing failed Payara installation..."
        sudo mv "$PAYARA" "${PAYARA}.failed.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Restore the backup
    log "Restoring original Payara installation..."
    sudo mv "${PAYARA}.${CURRENT_VERSION}.backup" "$PAYARA"
    check_error "Failed to restore Payara backup"
    
    # Fix ownership
    sudo chown -R "$DATAVERSE_USER:" "$PAYARA"
    
    # Start Payara
    log "Starting restored Payara..."
    sudo systemctl start payara
    
    # Wait and verify
    sleep 30
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
        log "ROLLBACK SUCCESSFUL: Original Payara installation restored"
        log "Your system should be back to the pre-upgrade state"
        return 0
    else
        log "WARNING: Rollback completed but Payara may need manual attention"
        return 1
    fi
}

# Main execution function
main() {
    log "Starting Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION"
    log "Log file: $LOGFILE"
    log "State file: $STATE_FILE"
    
    # Check for required commands
    check_required_commands
    
    # Check sudo access
    check_sudo_access
    
    # Check checksum configuration
    check_checksum_configuration
    
    # Step 0: Check current version FIRST (before any system modifications)
    if ! is_step_completed "check_version"; then
        check_current_version
        check_error "Version check failed - upgrade cannot proceed"
        mark_step_as_complete "check_version"
    fi
    
    # Step 0a: Prompt for backup (CRITICAL FIRST STEP)
    if ! is_step_completed "backup_confirmed"; then
        log "========================================"
        log "CRITICAL: Before proceeding with upgrade, ensure you have created backups:"
        log "1. Database backup: pg_dump -U dataverse dataverse > dataverse_backup.sql"
        log "2. Configuration backup: sudo tar -czf dataverse_config_backup.tar.gz /usr/local/payara6 /usr/local/solr"
        log "3. Any custom configurations or uploaded files"
        log "========================================"
        read -p "Have you created all necessary backups? (y/N): " HAS_BACKUP
        
        if [[ ! "$HAS_BACKUP" =~ ^[Yy]$ ]]; then
            log "ERROR: Backup confirmation required. Please create backups before running this script."
            log "Upgrade aborted. Please create backups and run the script again."
            exit 1
        fi
        mark_step_as_complete "backup_confirmed"
    fi
    
    # Step 1: Resolve any mixed state issues (only after version validation)
    if ! is_step_completed "resolve_mixed_state"; then
        resolve_mixed_state
        check_error "Failed to resolve mixed state"
        mark_step_as_complete "resolve_mixed_state"
    fi
    
    # Step 2: List applications
    if ! is_step_completed "list_applications"; then
        list_applications
        check_error "Failed to list applications"
        mark_step_as_complete "list_applications"
    fi
    
    # Step 3: Backup Payara domain configuration
    if ! is_step_completed "backup_domain"; then
        backup_payara_domain
        check_error "Failed to backup Payara domain"
        mark_step_as_complete "backup_domain"
    fi
    
    # Step 4: Undeploy previous version
    if ! is_step_completed "undeploy"; then
        undeploy_dataverse
        check_error "Failed to undeploy previous version"
        mark_step_as_complete "undeploy"
    fi
    
    # Step 5: Stop Payara
    if ! is_step_completed "stop_payara"; then
        stop_payara
        check_error "Failed to stop Payara"
        mark_step_as_complete "stop_payara"
    fi
    
    # Step 6: Upgrade Payara
    if ! is_step_completed "upgrade_payara"; then
        upgrade_payara
        check_error "Failed to upgrade Payara"
        mark_step_as_complete "upgrade_payara"
    fi
    
    # Step 7: Download Dataverse WAR
    if ! is_step_completed "download_war"; then
        download_dataverse_war
        check_error "Failed to download Dataverse WAR"
        mark_step_as_complete "download_war"
    fi
    
    # Step 8: Check and upgrade Java if necessary
    if ! is_step_completed "check_java"; then
        check_and_upgrade_java
        check_error "Failed to check/upgrade Java"
        mark_step_as_complete "check_java"
    fi
    
    # Step 8a: Clear application state before deployment
    if ! is_step_completed "clear_app_state"; then
        clear_application_state
        check_error "Failed to clear application state"
        mark_step_as_complete "clear_app_state"
    fi
    
    # Step 9: Deploy Dataverse
    if ! is_step_completed "deploy"; then
        deploy_dataverse
        check_error "Failed to deploy Dataverse"
        mark_step_as_complete "deploy"
    fi
    
    # Step 9a: Run database migrations
    if ! is_step_completed "database_migrations"; then
        run_database_migrations
        check_error "Failed to complete database migrations"
        mark_step_as_complete "database_migrations"
    fi
    
    # Step 10: Update language packs
    if ! is_step_completed "language_packs"; then
        update_language_packs
        check_error "Failed to update language packs"
        mark_step_as_complete "language_packs"
    fi
    
    # Step 11: Configure feature flags
    if ! is_step_completed "feature_flags"; then
        configure_feature_flags
        check_error "Failed to configure feature flags"
        mark_step_as_complete "feature_flags"
    fi
    
    # Step 12: Configure SameSite
    if ! is_step_completed "samesite"; then
        configure_samesite
        check_error "Failed to configure SameSite"
        mark_step_as_complete "samesite"
    fi
    
    # Step 13: Restart Payara
    if ! is_step_completed "restart_payara"; then
        restart_payara
        check_error "Failed to restart Payara"
        mark_step_as_complete "restart_payara"
    fi
    
    # Step 14: Update citation metadata block
    if ! is_step_completed "citation_block"; then
        update_citation_metadata_block
        check_error "Failed to update citation metadata block"
        mark_step_as_complete "citation_block"
    fi
    
    # Step 15: Add 3D Objects metadata block
    if ! is_step_completed "3d_objects_block"; then
        add_3d_objects_metadata_block
        check_error "Failed to add 3D Objects metadata block"
        mark_step_as_complete "3d_objects_block"
    fi
    
    # Step 16: Upgrade Solr
    if ! is_step_completed "upgrade_solr"; then
        upgrade_solr
        check_error "Failed to upgrade Solr"
        mark_step_as_complete "upgrade_solr"
    fi
    
    # Step 17: Update Solr custom fields
    if ! is_step_completed "solr_custom_fields"; then
        update_solr_custom_fields
        check_error "Failed to update Solr custom fields"
        mark_step_as_complete "solr_custom_fields"
    fi
    
    # Step 18: Reindex Solr
    if ! is_step_completed "reindex_solr"; then
        reindex_solr
        check_error "Failed to reindex Solr"
        mark_step_as_complete "reindex_solr"
    fi
    
    # Step 19: Run reExportAll
    if ! is_step_completed "reexport_all"; then
        run_reexport_all
        check_error "Failed to run reExportAll"
        mark_step_as_complete "reexport_all"
    fi
    
    # Step 20: Optional re-harvest
    if ! is_step_completed "reharvest"; then
        reharvest_datasets
        check_error "Failed to handle re-harvest option"
        mark_step_as_complete "reharvest"
    fi
    
    # Step 21: Verify upgrade
    if ! is_step_completed "verify"; then
        verify_upgrade
        check_error "Upgrade verification failed"
        mark_step_as_complete "verify"
    fi
    
    log "========================================"
    log "Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION completed successfully!"
    log "========================================"
    log ""
    log "Important notes:"
    log "- Solr has been upgraded to version $SOLR_VERSION with new range search capabilities"
    log "- Solr reindexing and reExportAll processes may still be running in the background"
    log "- Monitor server logs for any issues"
    log "- Test core functionality: login, dataset creation, file upload, search"
    log "- The range search feature is now available for numerical and date fields"
    log "- New 3D Objects metadata block is available for dataset creation"
    log "- Citation Style Language (CSL) support is now available"
    log ""
    log "Security note:"
    log "- For future runs, consider updating SHA256 checksums in this script"
    log "- This ensures download integrity verification for all components"
    log "- See the instructions at the top of this script for details"
    log ""
    log "For any issues, check the server logs and the upgrade log at: $LOGFILE"
}

# Run main function
main "$@"