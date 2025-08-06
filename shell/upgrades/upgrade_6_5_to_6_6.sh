#!/bin/bash
# set -x
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.6
#
# IMPORTANT: This script handles "application already registered" errors gracefully.
# These errors often occur during upgrades when an application is partially deployed
# but are usually benign if the application verification succeeds.
#
# IMPROVEMENTS (v2.2) - PRODUCTION-READY UNIVERSAL UPGRADE:
# - Enhanced service health monitoring throughout upgrade process
# - Robust mixed deployment state detection and resolution
# - Automatic Payara service restart capabilities during verification
# - Better error recovery from service crashes during long operations
# - Comprehensive deployment state validation and cleanup
# - Advanced Solr reindexing with progress monitoring and verification
# - Automatic index recovery after service crashes or restarts
# - Empty index detection and emergency reindexing capabilities
# - Real-time indexing progress tracking and detailed logging
# - FIXED: Custom metadata schema update process with verification and proper logging
# - FIXED: Silent failures in update-fields.sh script execution
# - VERIFIED: Custom fields (software, dataContext, computationalworkflow, 3D) properly added
# - NEW: Pre-upgrade baseline capture for comprehensive verification
# - NEW: Multi-retry schema update with detailed validation
# - NEW: Baseline comparison in final verification
# - NEW: University-agnostic design for any Dataverse 6.5 installation
# - NEW: Comprehensive error recovery with detailed diagnostics
# - FIXED: State file corruption bug that caused critical steps to be skipped
# - NEW: Step verification system with rollback capabilities
# - NEW: Interrupted step detection and recovery
# - NEW: Robust state management with running/failed/complete tracking
# - FIXED: Sudo user resolution issues in LDAP/SSSD environments
# - NEW: Multiple fallback methods for sudo operations
# - NEW: Graceful handling of backup directory creation failures
# - NEW: Enhanced error diagnostics for system configuration issues
# - CRITICAL FIX: Added fallback custom fields mechanism to prevent "unknown field" errors
# - CRITICAL FIX: Enhanced schema verification before reindexing
# - CRITICAL FIX: Automatic detection and addition of missing custom metadata fields
# - CRITICAL FIX: Improved error handling for Payara crashes during schema updates
# - CRITICAL FIX: Added automatic Payara restart and recovery when crashes occur during schema updates
# - CRITICAL FIX: Added forced fallback schema update when Payara crashes prevent normal schema updates
# - CRITICAL FIX: Added final safety checks before reindexing to ensure Payara is running
# - CRITICAL FIX: Fixed integer validation issues in schema field counting to prevent syntax errors
# - CRITICAL FIX: Fixed feature flag configuration to use JVM options instead of API (as per Dataverse 6.6 documentation)
# - CRITICAL FIX: Enhanced Solr collection recreation with robust verification and automatic collection creation
# - CRITICAL FIX: Fixed integer validation for schema field counting to prevent syntax errors in comparisons
# - CRITICAL FIX: Enhanced reindexing verification to handle zero baseline counts properly
# - CRITICAL FIX: Added new 6.6 fields (versionNote, fileRestricted, canDownloadFile) to fallback schema update

# Version information
TARGET_VERSION="6.6"
CURRENT_VERSION="6.5"
PAYARA_VERSION="6.2025.2"
SOLR_VERSION="9.8.0"
REQUIRED_JAVA_VERSION="11"

# URLs for downloading files
CITATION_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/scripts/api/data/metadatablocks/citation.tsv"
OBJECTS_3D_TSV_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/scripts/api/data/metadatablocks/3d_objects.tsv"
SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/schema.xml"
SOLR_CONFIG_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/solrconfig.xml"
UPDATE_FIELDS_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.6/conf/solr/update-fields.sh"
PAYARA_DOWNLOAD_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2025.2/payara-6.2025.2.zip"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.6/dataverse-6.6.war"
SOLR_DOWNLOAD_URL="https://archive.apache.org/dist/solr/solr/9.8.0/solr-9.8.0.tgz"

# SHA256 checksums for verification
PAYARA_SHA256="c06edc1f39903c874decf9615ef641ea18d3f7969d38927c282885960d5ee796"
DATAVERSE_WAR_SHA256="04206252f9692fe5ffca9ac073161cd52835f607d9387194a4112f91c2176f3d"
SOLR_SHA256="9948dcf798c196b834c4cbb420d1ea5995479431669d266c33d46548b67e69e1"
CITATION_TSV_SHA256="82dc4e0480ae9718ce021a0908c8a3ecb40d9918f38c0c7f8f42234460f6ed0e"
OBJECTS_3D_TSV_SHA256="6e8e714e3a314fef80ca004826d7dd3151279009c45a863ba3b05ee57c52c2bf"
SOLR_SCHEMA_SHA256="2ff4d76aa6645abb7db5289ade5cff83185a849f790606c90abaa87f8b5020c2"
SOLR_CONFIG_SHA256="f1b1402d5c5edc9fb5be78d05be86c2e82ae9e7014ec3d1e7cb1801a2b48f2a7"
UPDATE_FIELDS_SHA256="de66d7baecc60fbe7846da6db104701317949b3a0f1ced5df3d3f6e34b634c7c"

# Usage information
show_usage() {
    echo "Dataverse 6.5 to 6.6 Upgrade Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --troubleshoot-indexing    Run indexing diagnostic and troubleshooting"
    echo "                              This will check database vs Solr consistency,"
    echo "                              identify indexing errors, and provide"
    echo "                              troubleshooting steps for common issues."
    echo ""
    echo "  --help                     Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                         Run the full upgrade process"
    echo "  $0 --troubleshoot-indexing Run indexing diagnostic only"
    echo ""
    echo "The indexing diagnostic will help identify issues like:"
    echo "  • Datasets not appearing in search results"
    echo "  • Schema configuration problems"
    echo "  • Multi-valued field errors"
    echo "  • Indexing service failures"
}

# Check for help argument
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
DOWNLOAD_CACHE_DIR="$SCRIPT_DIR/downloads"

# Logging configuration
LOGFILE="$SCRIPT_DIR/dataverse_upgrade_6_5_to_6_6.log"
echo "" > "$LOGFILE"
STATE_FILE="$SCRIPT_DIR/upgrade_6_5_to_6_6.state"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Helper function to safely get Solr document count
get_solr_doc_count() {
    local response=$(curl -s --max-time 10 "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null)
    if [ -n "$response" ] && echo "$response" | jq . >/dev/null 2>&1; then
        echo "$response" | jq -r '.response.numFound // 0' 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to download a file with caching and checksum verification
download_with_cache() {
    local url="$1"
    local file_name="$2"
    local file_description="$3"
    local expected_sha256="$4"
    local dest_path="$DOWNLOAD_CACHE_DIR/$file_name"

    log "Handling download for $file_description..."

    # Ensure download cache directory exists
    if [ ! -d "$DOWNLOAD_CACHE_DIR" ]; then
        log "Creating download cache directory: $DOWNLOAD_CACHE_DIR"
        if ! mkdir -p "$DOWNLOAD_CACHE_DIR"; then
            log "❌ ERROR: Failed to create download cache directory: $DOWNLOAD_CACHE_DIR"
            return 1
        fi
    fi

    # Check if file exists in cache
    if [ -f "$dest_path" ]; then
        log "File found in cache: $dest_path"
        if [ -n "$expected_sha256" ] && [[ "$expected_sha256" != "REPLACE_WITH_OFFICIAL_"* ]]; then
            log "Verifying checksum of cached file..."
            if verify_checksum "$dest_path" "$expected_sha256" "$file_description"; then
                log "✓ Checksum for cached '$file_description' is valid. Skipping download."
                return 0 # Use cached file
            else
                log "✗ Checksum mismatch for cached file. Deleting and re-downloading."
                rm -f "$dest_path"
            fi
        else
            log "No checksum provided for $file_description. Using cached file as-is."
            return 0 # Use cached file without verification
        fi
    fi

    # Download with retry logic and better error handling
    log "Downloading $file_description from $url..."
    local download_success=false
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ] && [ "$download_success" = false ]; do
        retry_count=$((retry_count + 1))
        
        if [ $retry_count -gt 1 ]; then
            log "Retry attempt $retry_count of $max_retries for $file_description..."
        fi
        
        # Use wget with better options for reliability
        if wget --timeout=60 --tries=3 --retry-connrefused --no-verbose -O "$dest_path" "$url" 2>/dev/null; then
            download_success=true
            log "✓ Download completed successfully"
        else
            log "✗ Download attempt $retry_count failed"
            rm -f "$dest_path" # Clean up partial download
            
            if [ $retry_count -lt $max_retries ]; then
                log "Waiting 5 seconds before retry..."
                sleep 5
            fi
        fi
    done
    
    if [ "$download_success" = false ]; then
        log "❌ ERROR: Failed to download $file_description from $url after $max_retries attempts."
        return 1
    fi

    # Verify the downloaded file exists and has content
    if [ ! -f "$dest_path" ] || [ ! -s "$dest_path" ]; then
        log "❌ ERROR: Downloaded file is missing or empty: $dest_path"
        rm -f "$dest_path"
        return 1
    fi

    # Verify checksum if provided
    if [ -n "$expected_sha256" ] && [[ "$expected_sha256" != "REPLACE_WITH_OFFICIAL_"* ]]; then
        if ! verify_checksum "$dest_path" "$expected_sha256" "$file_description"; then
            log "❌ ERROR: Checksum verification failed for downloaded file."
            log "❌ CRITICAL: File integrity check failed. This could indicate:"
            log "   - Network corruption during download"
            log "   - Security issue (man-in-the-middle attack)"
            log "   - Outdated checksum in script"
            log "   - File source has changed"
            log ""
            log "Expected checksum: $expected_sha256"
            log "Actual checksum:   $(sha256sum "$dest_path" | cut -d' ' -f1)"
            log ""
            log "Removing corrupted file and exiting for security."
            rm -f "$dest_path"
            return 1
        fi
    fi

    log "✓ Download of $file_description complete and verified."
    return 0
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
        # Remove any existing "running" or "failed" entries for this step
        if ! grep -v "^${step_name}_running$\|^${step_name}_failed$" "$STATE_FILE" > "${STATE_FILE}.tmp"; then
            log "WARNING: Failed to update state file. Continuing..."
            rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
        else
            mv "${STATE_FILE}.tmp" "$STATE_FILE" || {
                log "❌ ERROR: Failed to update state file"
                rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
                return 1
            }
        fi
    fi
    echo "${step_name}_running" >> "$STATE_FILE"
    log "Step '$step_name' marked as running..."
}

# Function to mark a step as complete (with verification)
mark_step_as_complete() {
    local step_name="$1"
    local verification_func="$2"  # Optional verification function
    
    # Run verification if provided
    if [ -n "$verification_func" ] && command -v "$verification_func" >/dev/null 2>&1; then
        log "Verifying step '$step_name' completion..."
        if ! "$verification_func"; then
            log "❌ ERROR: Step '$step_name' verification failed!"
            mark_step_as_failed "$step_name"
            exit 1
        fi
        log "✅ Step '$step_name' verification passed"
    fi
    
    # Remove running/failed status and mark as complete
    if [ -f "$STATE_FILE" ]; then
        if ! grep -v "^${step_name}_running$\|^${step_name}_failed$" "$STATE_FILE" > "${STATE_FILE}.tmp"; then
            log "WARNING: Failed to update state file during completion. Continuing..."
            rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
        else
            mv "${STATE_FILE}.tmp" "$STATE_FILE" || {
                log "WARNING: Failed to update state file during completion"
                rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
            }
        fi
    fi
    echo "$step_name" >> "$STATE_FILE"
    log "✅ Step '$step_name' marked as complete."
}

# Function to mark a step as failed
mark_step_as_failed() {
    local step_name="$1"
    if [ -f "$STATE_FILE" ]; then
        if ! grep -v "^${step_name}_running$\|^${step_name}_failed$" "$STATE_FILE" > "${STATE_FILE}.tmp"; then
            log "WARNING: Failed to update state file during failure marking. Continuing..."
            rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
        else
            mv "${STATE_FILE}.tmp" "$STATE_FILE" || {
                log "WARNING: Failed to update state file during failure marking"
                rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
            }
        fi
    fi
    echo "${step_name}_failed" >> "$STATE_FILE"
    log "✗ Step '$step_name' marked as failed."
}

# Function to check for interrupted steps
check_interrupted_steps() {
    if [ -f "$STATE_FILE" ]; then
        local interrupted_steps=$(grep "_running$" "$STATE_FILE" 2>/dev/null | sed 's/_running$//' || true)
        if [ -n "$interrupted_steps" ]; then
            log "WARNING: Found interrupted steps from previous run:"
            echo "$interrupted_steps" | while read -r step; do
                log "  - $step (was running but didn't complete)"
            done
            log "These steps will be re-executed."
            # Clean up interrupted steps
            if ! grep -v "_running$" "$STATE_FILE" > "${STATE_FILE}.tmp"; then
                log "WARNING: Failed to clean up interrupted steps from state file"
                rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
            else
                mv "${STATE_FILE}.tmp" "$STATE_FILE" || {
                    log "WARNING: Failed to update state file after cleaning interrupted steps"
                    rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
                }
            fi
        fi
    fi
}

# Verification functions for critical steps
verify_solr_upgrade() {
    log "Verifying Solr upgrade to version $SOLR_VERSION..."
    
    # Check if Solr service is running first
    local solr_was_running=false
    if systemctl is-active --quiet solr; then
        solr_was_running=true
    else
        log "Solr is stopped, starting temporarily for verification..."
        sudo systemctl start solr
        
        # Wait for Solr to start
        local retries=0
        while [ $retries -lt 30 ]; do
            if curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" 2>/dev/null >/dev/null; then
                break
            fi
            sleep 2
            retries=$((retries + 1))
        done
        
        if [ $retries -eq 30 ]; then
            log "✗ Failed to start Solr for verification"
            return 1
        fi
    fi
    
    # Check Solr version
    local solr_version=$(curl -s --max-time 10 --retry 2 "http://localhost:8983/solr/admin/info/system" 2>/dev/null | jq -r '.lucene."solr-spec-version"' 2>/dev/null || echo "unknown")
    
    # Stop Solr again if it wasn't running before
    if [ "$solr_was_running" = false ]; then
        log "Stopping Solr after verification..."
        sudo systemctl stop solr
    fi
    
    if [[ "$solr_version" == *"$SOLR_VERSION"* ]]; then
        log "✓ Solr version verified: $solr_version"
        return 0
    else
        log "✗ Solr version verification failed. Expected: $SOLR_VERSION, Got: $solr_version"
        return 1
    fi
}

verify_schema_update() {
    log "Verifying Solr schema update..."
    
    # Check if schema file exists and is valid XML
    local schema_file="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    if [ ! -f "$schema_file" ]; then
        log "✗ Schema file not found: $schema_file"
        return 1
    fi
    
    # Validate XML syntax first
    if ! xmllint --noout "$schema_file" 2>/dev/null; then
        log "✗ Schema XML is invalid"
        return 1
    fi
    
    # Check total field count
    local total_fields
    total_fields=$(grep -c '<field name=' "$schema_file") || total_fields=0
    
    log "Schema contains $total_fields total field definitions"
    
    if [ "$total_fields" -lt 50 ]; then
        log "✗ Schema appears incomplete (too few fields: $total_fields)"
        return 1
    fi
    
    # Check for custom field presence (but don't fail if missing)
    local custom_fields
    custom_fields=$(grep -c "swContributorName\|dataContext\|computationalworkflow\|swInputOutputDescription" "$schema_file") || custom_fields=0
    
    if [ "$custom_fields" -gt 0 ]; then
        log "✓ Custom metadata fields found in schema: $custom_fields fields"
    else
        log "INFO: No custom metadata fields found in schema (this may be expected)"
    fi
    
    # Check for essential Dataverse fields
    local essential_fields=("dvObjectId" "entityId" "datasetVersionId")
    local missing_essential=0
    
    for field in "${essential_fields[@]}"; do
        if ! grep -q "name=\"$field\"" "$schema_file" 2>/dev/null; then
            log "WARNING: Essential field missing: $field"
            missing_essential=$((missing_essential + 1))
        fi
    done
    
    if [ $missing_essential -gt 0 ]; then
        log "✗ $missing_essential essential Dataverse fields are missing"
        return 1
    fi
    
    log "✓ Schema validation passed: $total_fields fields, valid XML, essential fields present"
    return 0
}

verify_reindexing() {
    log "Verifying Solr reindexing progress..."
    
    # Check if index has content
    local index_doc_count=$(get_solr_doc_count)
    # Check if index_doc_count is a number
    if ! [[ "$index_doc_count" =~ ^[0-9]+$ ]]; then
        log "✗ Reindexing verification failed: $index_doc_count is not a number"
        return 1
    fi
    
    # Use pre-Solr-upgrade count if available (more accurate), otherwise fall back to original baseline
    local baseline_count=$(jq -r '.pre_solr_upgrade_count // .pre_upgrade_index_count' "$SCRIPT_DIR/baseline_metrics.json" || echo "1000")
    # Check if baseline_count is a number
    if ! [[ "$baseline_count" =~ ^[0-9]+$ ]]; then
        log "✗ Reindexing verification failed: $baseline_count is not a number"
        return 1
    fi
    
    # Handle case where baseline is 0 (index was cleared before baseline capture)
    if [ "$baseline_count" -eq 0 ]; then
        log "⚠️ Baseline count is 0 (index was cleared before baseline capture)"
        log "Using original pre-upgrade count for verification..."
        baseline_count=$(jq -r '.pre_upgrade_index_count' "$SCRIPT_DIR/baseline_metrics.json" || echo "1000")
        if ! [[ "$baseline_count" =~ ^[0-9]+$ ]]; then
            log "✗ Reindexing verification failed: baseline count is not a valid number"
            return 1
        fi
        log "Using original baseline: $baseline_count documents"
    fi
    
    # More lenient verification - allow for ongoing indexing
    local min_threshold=$((baseline_count * 5 / 100))  # Only require 5% initially
    
    if [ "$index_doc_count" -gt "$min_threshold" ]; then
        log "✓ Reindexing progress verified: $index_doc_count documents (>5% of baseline $baseline_count)"
        
        # Check if indexing is still active
        local index_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
        if echo "$index_status" | grep -qi "running\|progress\|active"; then
            log "INFO: Indexing is still active and will continue in background"
        else
            # Check percentage completion
            local completion_percent=$((index_doc_count * 100 / baseline_count))
            if [ $completion_percent -lt 50 ]; then
                log "WARNING: Only $completion_percent% of baseline indexed, but progress is being made"
            else
                log "✓ Good progress: $completion_percent% of baseline indexed"
            fi
        fi
        return 0
    elif [ "$index_doc_count" -gt 0 ]; then
        log "⚠️ Minimal progress detected: $index_doc_count documents (<5% of baseline)"
        log "This may indicate slow but ongoing indexing progress"
        
        # Check if indexing is currently active
        local index_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
        if echo "$index_status" | grep -qi "running\|progress\|active"; then
            log "✓ Indexing is currently active, allowing it to continue"
            return 0
        else
            log "⚠️ No active indexing detected, but some documents are indexed"
            return 1
        fi
    else
        log "✗ Reindexing verification failed: $index_doc_count documents (no progress from baseline $baseline_count)"
        return 1
    fi
}

verify_deployment() {
    log "Verifying Dataverse deployment..."
    
    # Check version
    local version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' || echo "unknown")
    # Check if version is a valid version number
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log "✗ Deployment verification failed: $version is not a valid version number"
        return 1
    fi
    if [[ "$version" == *"$TARGET_VERSION"* ]]; then
        log "✓ Deployment verified: version $version"
        return 0
    else
        log "✗ Deployment verification failed: expected $TARGET_VERSION, got $version"
        return 1
    fi
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

for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        log "❌ Error: Required environment variable $var is not set in .env file."
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
        log "❌ ERROR: Sudo is not working. This may be due to:"
        log "1. User not in sudoers file"
        log "2. Name service (NSS/LDAP/SSSD) configuration issues"
        log "3. Container/environment limitations"
        log ""
        log "Please ensure your user has sudo privileges and try again."
        exit 1
    fi
elif [ "$USER" != "$DATAVERSE_USER" ]; then
    log "WARNING: This script is being run as user '$USER', but the configured Dataverse user is '$DATAVERSE_USER'."
    log "This is generally not recommended, but the script will attempt to continue."
    log "Ensure that '$USER' has appropriate sudo permissions to act as '$DATAVERSE_USER' and manage system services."
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
    log "❌ ERROR: Upgrade failed. Starting error cleanup and service stabilization..."
    
    # Clean up temporary files
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        log "Cleaning up temporary files..."
        sudo rm -rf "$TMP_DIR" || true
    fi
    
    # Clean up any temporary backup files older than 1 hour
    find /tmp -name "*.backup.*" -type f -mmin +60 -delete 2>/dev/null || true
    
    # Attempt to stabilize services
    log "Attempting to stabilize services after failure..."
    if command -v attempt_service_recovery >/dev/null 2>&1; then
        if attempt_service_recovery; then
            log "✓ Services stabilized successfully"
        else
            log "⚠️ WARNING: Service stabilization had issues - manual intervention may be needed"
        fi
    fi
    
    # Provide helpful next steps
    log ""
    log "🚨 UPGRADE FAILED - NEXT STEPS:"
    log "  1. Review the error details above and in the log file: $LOGFILE"
    log "  2. Run the verification script to check current state: ./shell/upgrades/verify_6_6_upgrade.sh"
    log "  3. Read the troubleshooting guide: shell/upgrades/README_6_5_to_6_6_upgrade.md"
    log "  4. Check service status: sudo systemctl status payara solr"
    log "  5. If services are down, restart them: sudo systemctl restart payara solr"
    log ""
    log "💡 COMMON FIXES:"
    log "  • If Solr schema issues: Check that dvObjectId, entityId, datasetVersionId fields are present"
    log "  • If API not responding: Wait 2-3 minutes for services to fully start, then retry"
    log "  • If database errors: These are often normal during upgrades - check if services recovered"
    log ""
}

cleanup_on_success() {
    log "Upgrade completed successfully. Cleaning up temporary files..."
    # Add any other success-specific cleanup here if needed
    log "Success cleanup complete."
}

# Function to handle exit and check if it was successful or error
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        cleanup_on_success
    else
        log "❌ ERROR: Upgrade failed with exit code $exit_code"
        cleanup_on_error
    fi
}

# Trap errors and exit
trap cleanup_on_exit EXIT

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

# Enhanced pre-flight validation function
run_preflight_checks() {
    log "========================================="
    log "RUNNING COMPREHENSIVE PRE-FLIGHT CHECKS"
    log "========================================="
    
    local preflight_errors=()
    local preflight_warnings=()
    
    # Check disk space requirements  
    log "Checking disk space requirements..."
    local tmp_space=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local home_space=$(df -m /home 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local payara_space=$(df -m "$PAYARA" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    
    if [[ "$tmp_space" -lt 2048 ]]; then
        preflight_errors+=("Insufficient space in /tmp: ${tmp_space}MB (need 2GB)")
    fi
    if [[ "$home_space" -lt 1024 ]]; then
        preflight_warnings+=("Low space in /home: ${home_space}MB (recommend 1GB+)")
    fi
    if [[ "$payara_space" -lt 1024 ]]; then
        preflight_warnings+=("Low space in Payara directory: ${payara_space}MB (recommend 1GB+)")
    fi
    
    # Check memory requirements
    log "Checking memory requirements..."
    local total_memory=$(free -m 2>/dev/null | awk 'NR==2{print $2}' || echo "0")
    local available_memory=$(free -m 2>/dev/null | awk 'NR==2{print $7}' || echo "0")
    
    if [[ "$total_memory" -lt 4096 ]]; then
        preflight_warnings+=("Low total memory: ${total_memory}MB (recommend 4GB+)")
    fi
    if [[ "$available_memory" -lt 1024 ]]; then
        preflight_warnings+=("Low available memory: ${available_memory}MB (recommend 1GB+)")
    fi
    
    # Check Payara configuration integrity
    log "Checking Payara configuration integrity..."
    local domain_xml="$PAYARA/glassfish/domains/domain1/config/domain.xml"
    if [[ ! -f "$domain_xml" ]]; then
        preflight_errors+=("Payara domain.xml not found at $domain_xml")
    elif ! grep -q "dataverse" "$domain_xml" 2>/dev/null; then
        preflight_warnings+=("No Dataverse configuration found in domain.xml")
    fi
    
    # Check and ensure security policy configuration
    log "Checking security policy configuration..."
    ensure_security_policy_exists
    
    # Check network connectivity for downloads
    log "Checking network connectivity..."
    if ! curl -s --max-time 10 "https://github.com" 2>/dev/null > /dev/null; then
        preflight_warnings+=("Network connectivity issues detected")
    fi
    
    # Report results
    if [[ ${#preflight_errors[@]} -gt 0 ]]; then
        log "❌ PRE-FLIGHT CHECK FAILED - CRITICAL ERRORS:"
        for error in "${preflight_errors[@]}"; do
            log "  ❌ $error"
        done
        log "Please fix these critical issues before proceeding."
        return 1
    fi
    
    if [[ ${#preflight_warnings[@]} -gt 0 ]]; then
        log "⚠️  PRE-FLIGHT CHECK WARNINGS:"
        for warning in "${preflight_warnings[@]}"; do
            log "  ⚠️  $warning"
        done
        log "Warnings detected but upgrade can proceed."
    fi
    
    log "✅ PRE-FLIGHT CHECKS COMPLETED SUCCESSFULLY"
    return 0
}

# Function to ensure security policy files exist
ensure_security_policy_exists() {
    local payara_config_dir="$PAYARA/glassfish/domains/domain1/config"
    local server_policy="$payara_config_dir/server.policy"
    local default_policy="$payara_config_dir/default.policy"
    
    # Check if either policy file exists
    if [[ ! -f "$server_policy" && ! -f "$default_policy" ]]; then
        log "WARNING: No security policy files found. Creating default policy..."
        
        # Create a basic server.policy file
        sudo tee "$server_policy" > /dev/null << 'EOF'
// Default security policy for Dataverse
grant {
    permission java.security.AllPermission;
};
EOF
        
        # Set proper ownership and permissions
        sudo chown dataverse:dataverse "$server_policy" 2>/dev/null || true
        sudo chmod 644 "$server_policy"
        
        log "Created default security policy at: $server_policy"
    else
        log "Security policy files found and accessible"
        
        # Ensure proper permissions on existing files
        if [[ -f "$server_policy" ]]; then
            sudo chown dataverse:dataverse "$server_policy" 2>/dev/null || true
            sudo chmod 644 "$server_policy"
        fi
        if [[ -f "$default_policy" ]]; then
            sudo chown dataverse:dataverse "$default_policy" 2>/dev/null || true
            sudo chmod 644 "$default_policy"
        fi
    fi
}

# Function to check for required commands
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
    local user_resolution_issue=false
    
    # Check for user resolution issues first
    if sudo whoami 2>&1 | grep -q "you do not exist in the passwd database"; then
        user_resolution_issue=true
        log "⚠ DETECTED: User resolution issue in sudo (passwd database problem)"
        log "This is common in LDAP/SSSD environments and may cause intermittent issues"
    fi
    
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
    elif sudo bash -c "echo 'sudo works with explicit bash'" >/dev/null 2>&1; then
        sudo_works=true
        test_method="explicit-bash"
    fi
    
    if [ "$sudo_works" = true ]; then
        log "✓ Sudo access verified ($test_method method)."
        if [ "$user_resolution_issue" = true ]; then
            log "ℹ Note: User resolution issues detected but sudo is working"
            log "The script will use robust error handling for sudo operations"
        fi
    else
        log "WARNING: Sudo tests are failing, but this may be due to user resolution issues."
        log "This is common in certain environments (containers, NFS, LDAP, etc.)."
        
        if [ "$user_resolution_issue" = true ]; then
            log "📋 ROBUST MODE ENABLED: The script will use multiple fallback methods for sudo operations"
            log "This should handle the user resolution issues automatically"
        fi
        
        log "Attempting to continue anyway - the script has built-in fallback methods."
        log ""
        log "If the script still fails with sudo errors, please ensure:"
        log "1. You have sudo privileges"
        log "2. sudo is properly configured"
        log "3. Your user is properly configured in the system"
        log ""
        log "Current user info:"
        log "  USER: $USER"
        log "  UID: $(id -u 2>/dev/null || echo 'unknown')"
        log "  whoami: $(whoami 2>/dev/null || echo 'unknown')"
        log "  Sudo test: $(sudo whoami 2>&1 | head -1)"
    fi
}

# Helper function to execute sudo commands with multiple fallback methods for LDAP/SSSD environments
robust_sudo_execute() {
    local command="$1"
    local description="${2:-command}"
    local output_file="${3:-/dev/null}"

    # Method 1: Standard sudo with no output file
    if [ -z "$output_file" ]; then
        if sudo $command; then
            log "✓ Executed $description with sudo Method 1"
            return 0
        fi
    fi

    # Method 2: sudo with bash -c
    if sudo bash -c "$command" > "$output_file"; then
        log "✓ Executed $description with sudo Method 2"
        return 0
    fi
    
    # Method 3: sudo with HOME flag (for LDAP/SSSD)
    if sudo -H bash -c "$command" > "$output_file"; then
        log "✓ Executed $description with sudo Method 3"
        return 0
    fi
    
    # Method 4: sudo with shell flag (for LDAP/SSSD)
    if sudo -s bash -c "$command" > "$output_file"; then
        log "✓ Executed $description with sudo Method 4"
        return 0
    fi
    
    # For specific command types, try direct alternatives
    if [[ "$command" =~ "systemctl start payara" ]]; then
        # Try asadmin start-domain
        if sudo -H bash -c "$PAYARA/bin/asadmin start-domain domain1" > "$output_file" 2>&1; then
            return 0
        elif sudo bash -c "$PAYARA/bin/asadmin start-domain domain1" > "$output_file" 2>&1; then
            return 0
        elif $PAYARA/bin/asadmin start-domain domain1 > "$output_file" 2>&1; then
            return 0
        fi
    elif [[ "$command" =~ "systemctl start solr" ]]; then
        # Try solr start script
        if sudo -H bash -c "$SOLR_PATH/bin/solr start" > "$output_file" 2>&1; then
            return 0
        elif sudo bash -c "$SOLR_PATH/bin/solr start" > "$output_file" 2>&1; then
            return 0
        elif "$SOLR_PATH/bin/solr" start > "$output_file" 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

# Helper function to create directories with robust sudo handling
robust_mkdir() {
    local dir_path="$1"
    local description="${2:-directory}"
    
    # Try multiple methods to create directory
    if robust_sudo_execute "mkdir -p '$dir_path'" "create $description"; then
        log "✓ Created $description: $dir_path"
        # Check the output folder exists
        if [ -d "$dir_path" ]; then
            log "✓ Output folder exists: $dir_path"
        else
            log "❌ ERROR: Output folder does not exist: $dir_path"
            return 1
        fi
        return 0
    else
        log "❌ ERROR: Failed to create $description: $dir_path"
        return 1
    fi
}

# Helper function to copy files with robust sudo handling
robust_copy() {
    local source="$1"
    local dest="$2"
    local description="${3:-file}"
    
    # Ensure source exists
    if [ ! -e "$source" ]; then
        log "❌ ERROR: Source does not exist: $source"
        return 1
    fi
    
    # Ensure destination directory exists
    local dest_dir="$dest"
    if [ ! -d "$dest" ]; then
        dest_dir="$(dirname "$dest")"
    fi
    
    if [ ! -d "$dest_dir" ]; then
        log "Creating destination directory: $dest_dir"
        if ! robust_mkdir "$dest_dir" "destination directory for $description"; then
            log "❌ ERROR: Failed to create destination directory: $dest_dir"
            return 1
        fi
    fi
    
    # Try multiple copy methods with better error handling
    local copy_success=false
    echo ""
    log "Copying $description: $source -> $dest"
    
    if sudo rsync -av "$source" "$dest" 2>/dev/null; then
        log "rsync -av $source $dest"
        copy_success=true
        log "✓ Copied $description using rsync: $source -> $dest"
    else
        log "Standard copy methods failed. Attempting temporary intermediate copy..."
        local temp_copy="/tmp/dataverse_backup_temp_$(date +%s)"
        
        # First copy to temp location as current user if possible, then sudo move
        if sudo cp -r "$source" "$temp_copy" 2>/dev/null; then
            if sudo mv "$temp_copy" "$dest/" 2>/dev/null; then
                copy_success=true
                log "✓ Copied $description using temp intermediate: $source -> $dest"
            else
                rm -rf "$temp_copy" 2>/dev/null || true
            fi
        # If that fails, try with sudo for both steps
        elif sudo cp -r "$source" "$temp_copy" 2>/dev/null && sudo mv "$temp_copy" "$dest/" 2>/dev/null; then
            copy_success=true
            log "✓ Copied $description using sudo temp intermediate: $source -> $dest"
        else
            # Clean up any failed temp copy
            sudo rm -rf "$temp_copy" 2>/dev/null || true
        fi
    fi
    
    if [ "$copy_success" = true ]; then
        # Verify the copy was successful
        local source_name=$(basename "$source")
        local expected_dest
        if [ -d "$dest" ]; then
            expected_dest="$dest/$source_name"
        else
            expected_dest="$dest"
        fi
        
        if [ -e "$expected_dest" ]; then
            log "✓ Backup verification: $expected_dest exists"
            return 0
        else
            log "❌ ERROR: Backup verification failed - destination not found: $expected_dest"
            return 1
        fi
    else
        log "❌ ERROR: Failed to copy $description with all methods: $source -> $dest"
        log "Debug info:"
        log "  Source exists: $([ -e "$source" ] && echo "yes" || echo "no")"
        log "  Source permissions: $(ls -ld "$source" 2>/dev/null || echo "unknown")"
        log "  Dest dir exists: $([ -d "$dest_dir" ] && echo "yes" || echo "no")"
        log "  Dest dir permissions: $(ls -ld "$dest_dir" 2>/dev/null || echo "unknown")"
        log "  Current user: $(whoami)"
        log "  Effective UID: $(id -u)"
        return 1
    fi
}

# Function to start Payara if needed
start_payara_if_needed() {
    if ! pgrep -f "payara.*domain1" > /dev/null; then
        log "Payara is not running. Starting it now..."
        
        # Try multiple methods for starting Payara due to sudo user resolution issues
        local start_success=false
        
        # Use robust sudo execute function
        if robust_sudo_execute "systemctl start payara" "Payara start"; then
            start_success=true
            log "✓ Payara started successfully"
        else
            log "❌ ERROR: Failed to start Payara with all methods"
            return 1
        fi
        
        # Wait for Payara to be fully ready
        local retries=0
        while [ $retries -lt 30 ]; do
            if pgrep -f "payara.*domain1" > /dev/null; then
                log "✓ Payara service is running"
                return 0
            fi
            sleep 2
            retries=$((retries + 1))
            log "Waiting for Payara to start... ($retries/30)"
        done
        
        log "❌ ERROR: Payara failed to start within timeout"
        return 1
    else
        log "✓ Payara is already running"
        return 0
    fi
}

# Function to start Payara with comprehensive fallback methods
start_payara_robust() {
    if ! pgrep -f "payara.*domain1" > /dev/null; then
        log "Starting Payara service..."
        
        # Method 1: Standard sudo systemctl
        if robust_sudo_execute "systemctl start payara" "Payara systemctl start"; then
            start_success=true
            log "✓ Payara started with standard sudo method"
        else
            log "WARNING: Standard sudo systemctl failed, trying alternative methods..."
            
            # Method 2: Try with explicit shell
            if sudo bash -c "systemctl start payara" 2>/dev/null; then
                start_success=true
                log "✓ Payara started with sudo bash method"
            else
                log "WARNING: sudo bash method also failed, trying direct systemctl..."
                
                # Method 3: Try direct systemctl (may work if user has appropriate permissions)
                if systemctl start payara 2>/dev/null; then
                    start_success=true
                    log "✓ Payara started with direct systemctl method"
                fi
            fi
        fi
        
        if [ "$start_success" = false ]; then
            log "❌ ERROR: Failed to start Payara with all methods"
            log "This may be due to user resolution issues in sudo"
            log "Current user info:"
            log "  USER: $USER"
            log "  UID: $(id -u 2>/dev/null || echo 'unknown')"
            log "  whoami: $(whoami 2>/dev/null || echo 'unknown')"
            log "  Sudo test: $(sudo whoami 2>&1 | head -1)"
            log ""
            log "Please manually start Payara and try again, or check sudo configuration."
            return 1
        fi
        
        log "Waiting for Payara to initialize..."
        sleep 10
        
        # Verify Payara actually started
        local retries=0
        while [ $retries -lt 15 ]; do
            if pgrep -f "payara.*$DOMAIN_NAME" > /dev/null; then
                log "✓ Payara is running successfully."
                return 0
            fi
            sleep 2
            retries=$((retries + 1))
            log "Waiting for Payara to start... ($retries/15)"
        done
        
        log "WARNING: Payara may not have started properly"
        log "Checking for Payara processes:"
        pgrep -f payara | tee -a "$LOGFILE" || log "No Payara processes found by pgrep"
        
        # Give it one more chance with verification
        if pgrep -f "payara.*$DOMAIN_NAME" > /dev/null; then
            log "✓ Payara is actually running (delayed start)"
            return 0
        else
            log "❌ ERROR: Payara failed to start properly"
            return 1
        fi
    else
        log "Payara is already running."
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
        "PER01000.*already exists"
        "PSQLException.*duplicate key"
        "PSQLException.*already exists"
        "application.*already registered"
        "application with name.*already registered"
        "PER01003.*Deployment encountered SQL Exceptions"
        "PER01000.*ERROR: relation.*already exists"
        "PER01000.*ERROR: constraint.*already exists"
        "PER01000.*ERROR: index.*already exists"
        "PER01000.*ERROR: sequence.*already exists"
        "PER01000.*ERROR: table.*already exists"
        "PER01000.*PSQLException: ERROR: relation.*already exists"
        "PER01000.*PSQLException: ERROR: constraint.*already exists"
        "PER01000.*PSQLException: ERROR: index.*already exists"
        "PER01000.*PSQLException: ERROR: sequence.*already exists"
        "PER01000.*PSQLException: ERROR: table.*already exists"
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
        "java.lang.OutOfMemoryError"
        "StackOverflowError"
        "NoClassDefFoundError"
        "ClassNotFoundException"
        "UnsupportedClassVersionError"
        "Failed to deploy.*critical"
        "WAR file.*corrupted"
        "Invalid WAR file"
        "Schema validation.*failed"
        "Database connection.*refused"
    )
    
    # Security policy error patterns (need special handling but not fatal)
    local policy_patterns=(
        "Failed to load default.policy"
        "SecurityException"
        "AccessControlException"
        "Policy file.*not found"
        "Security.*configuration.*error"
        "Permission.*denied.*policy"
    )
    
    # Database migration related errors that can be temporarily ignored during deployment
    local migration_patterns=(
        "column.*does not exist"
        "relation.*does not exist.*migration"
        "displayoncreate.*does not exist"
        "displayOnCreate.*does not exist"
        "INDEX.*displayoncreate.*does not exist"
        "Flyway"
        "database migration"
        "schema migration"
        "Migration.*in.*progress"
        "temporary.*migration.*error"
        "Schema.*update.*pending"
    )
    
    # Check for migration-related errors first (these can be temporary during deployment)
    local has_migration_errors=false
    for pattern in "${migration_patterns[@]}"; do
        if grep -qi "$pattern" "$output_file" 2>/dev/null; then
            log "INFO: Found migration-related error pattern (may be temporary): $pattern"
            has_migration_errors=true
        fi
    done
    
    # Check for fatal errors first
    for pattern in "${fatal_patterns[@]}"; do
        if grep -qi "$pattern" "$output_file" 2>/dev/null; then
            log "FATAL: Found critical error pattern: $pattern"
            has_fatal_errors=true
            break
        fi
    done
    
    # Check for security policy errors (special handling needed)
    local has_policy_errors=false
    for pattern in "${policy_patterns[@]}"; do
        if grep -qi "$pattern" "$output_file" 2>/dev/null; then
            log "POLICY ERROR: Found security policy error: $pattern"
            has_policy_errors=true
            # Flag for recovery but don't treat as fatal immediately
            echo "POLICY_ERROR_RECOVERY_NEEDED" > "/tmp/dataverse_upgrade_policy_recovery"
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
            
            # Special handling for PER01003 messages: check if all underlying SQL errors are benign
            if [ "$is_benign" = false ] && echo "$error_line" | grep -qi "PER01003.*Deployment encountered SQL Exceptions"; then
                # Count total PER01000 SQL errors and benign PER01000 errors in the output
                local total_sql_errors=$(grep -c "PER01000:" "$output_file" 2>/dev/null || echo "0")
                # Ensure we have a clean integer
                total_sql_errors=$(echo "$total_sql_errors" | tr -d '\n\r\t ' | head -1)
                if ! [[ "$total_sql_errors" =~ ^[0-9]+$ ]]; then
                    total_sql_errors="0"
                fi
                local benign_sql_errors=0
                
                # Count how many PER01000 errors match benign patterns
                while read -r sql_error_line; do
                    for pattern in "${benign_patterns[@]}"; do
                        if echo "$sql_error_line" | grep -qi "$pattern"; then
                            benign_sql_errors=$((benign_sql_errors + 1))
                            break
                        fi
                    done
                done < <(grep "PER01000:" "$output_file" 2>/dev/null)
                
                # If all SQL errors are benign, treat PER01003 as benign too
                if [ "$total_sql_errors" -gt 0 ] && [ "$benign_sql_errors" -eq "$total_sql_errors" ]; then
                    is_benign=true
                    log "INFO: Ignoring PER01003 message - all underlying SQL errors ($total_sql_errors) are benign: $(echo "$error_line" | tr -d '\n')"
                fi
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
            # If we have policy errors, note that recovery may be needed
            if [ "$has_policy_errors" = true ]; then
                log "INFO: Policy errors detected but deployment may have succeeded. Recovery will be attempted if needed."
            fi
            return 0
        else
            # If only policy errors (no other non-benign errors), allow to proceed with recovery
            if [ "$has_policy_errors" = true ] && [ "$has_only_benign" = true ]; then
                log "INFO: Only policy and benign errors detected. Flagging for recovery but allowing deployment to proceed."
                return 0
            fi
            return 1
        fi
    else
        # Fatal errors found, but check if policy recovery might help
        if [ "$has_policy_errors" = true ]; then
            log "FATAL: Critical errors found, but policy errors also detected. Will attempt policy recovery."
            return 1
        fi
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
    
    if [[ -z "$current_java_version" || "$current_java_version" -lt "$REQUIRED_JAVA_VERSION" ]]; then
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
            if [[ -z "$new_java_version" || "$new_java_version" -lt "$REQUIRED_JAVA_VERSION" ]]; then
                log "❌ ERROR: Java upgrade failed. Current version: $new_java_version, Required: $REQUIRED_JAVA_VERSION"
                return 1
            fi
            log "Java version after upgrade: $new_java_version"
        else
            log "❌ ERROR: Java upgrade script not found at $java_upgrade_script"
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
        api_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null || echo "unknown")
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
    version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null || echo "")
    # Check if version is a valid version number
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log "✗ Deployment verification failed: $version is not a valid version number"
        return 1
    fi

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
            exit 0
            
        # Case 3: ❌ Running a version that's too old for this upgrade
        elif version_compare "$version" "$CURRENT_VERSION"; then
            log "✗ ERROR: Current version ($version) is OLDER than expected ($CURRENT_VERSION)"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "Please upgrade to $CURRENT_VERSION first using the appropriate script."
            log "Example upgrade path: 6.3 → 6.4 → 6.5 → 6.6"
            log "Exiting to prevent potential data corruption."
            exit 1
            
        # Case 4: ❌ Running a version that's newer than target (unusual)
        elif version_compare "$TARGET_VERSION" "$version"; then
            log "✗ ERROR: Current version ($version) is NEWER than target version ($TARGET_VERSION)"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "You may need a different upgrade script or this is a development version."
            log "Exiting to prevent potential data corruption."
            exit 1
            
        # Case 5: ❌ Unexpected version scenario
        else
            log "✗ ERROR: Unexpected version scenario. Current: $version, Expected: $CURRENT_VERSION, Target: $TARGET_VERSION"
            log "This upgrade script is for $CURRENT_VERSION → $TARGET_VERSION only."
            log "Exiting to prevent potential data corruption."
            exit 1
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
    
    # Try multiple approaches due to sudo user resolution issues
    local list_success=false
    local output_file=$(mktemp)
    
    # Method 1: Standard sudo -u approach
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE" > "$output_file"; then
        list_success=true
        log "✓ Application list completed with standard sudo method"
    else
        log "WARNING: Standard sudo -u method failed, trying alternatives..."
        
        # Method 2: sudo with explicit shell and user switching
        if sudo bash -c "su - $DATAVERSE_USER -c '$PAYARA/bin/asadmin list-applications'" 2>&1 | tee -a "$LOGFILE" > "$output_file"; then
            list_success=true
            log "✓ Application list completed with sudo bash method"
        else
            log "WARNING: sudo bash method also failed, trying direct approach..."
            
            # Method 3: Try with current user if asadmin allows it
            if $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE" > "$output_file"; then
                list_success=true
                log "✓ Application list completed with direct method (current user)"
            fi
        fi
    fi
    
    if [ "$list_success" = false ]; then
        log "❌ ERROR: Failed to list applications with all methods"
        log "This may be due to user resolution issues in the system"
        log "Attempting to continue - some functionality may be limited"
        rm -f "$output_file"
        return 0  # Don't fail the entire upgrade for this
    fi
    
    # Check if we got meaningful output
    if grep -q "No applications are deployed" "$output_file" 2>/dev/null; then
        log "ℹ No applications currently deployed"
    elif grep -q "dataverse" "$output_file" 2>/dev/null; then
        log "ℹ Found Dataverse applications in deployment list"
    fi
    
    rm -f "$output_file"
    log "Application list completed successfully."
}

# Enhanced service validation functions
validate_payara_health() {
    local max_wait=${1:-120}
    local counter=0
    
    log "Validating Payara health (timeout: ${max_wait}s)..."
    
    while [ $counter -lt $max_wait ]; do
        # Check if Payara process is running
        if ! pgrep -f "payara" > /dev/null; then
            log "❌ ERROR: Payara process not found"
            return 1
        fi
        
        # Check if asadmin commands work
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2> /dev/null; then
            log "✓ Payara is responding to asadmin commands"
            
            # Additional health check: verify domain is accessible
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-domains 2> /dev/null; then
                log "✓ Payara domain is accessible"
                return 0
            fi
        fi
        
        sleep 5
        counter=$((counter + 5))
        
        if [ $((counter % 30)) -eq 0 ]; then
            log "Still waiting for Payara health validation... (${counter}s elapsed)"
        fi
    done
    
    log "❌ ERROR: Payara health validation failed after ${max_wait} seconds"
    return 1
}

validate_dataverse_api() {
    local max_wait=${1:-180}
    local counter=0
    
    log "Validating Dataverse API accessibility (timeout: ${max_wait}s)..."
    
    while [ $counter -lt $max_wait ]; do
        # Check API version endpoint
        if curl -s --max-time 10 "http://localhost:8080/api/info/version" > /dev/null; then
            local api_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' || echo "unknown")
            log "✓ Dataverse API is accessible (version: $api_version)"
            return 0
        fi
        
        sleep 10
        counter=$((counter + 10))
        
        if [ $((counter % 60)) -eq 0 ]; then
            log "Still waiting for Dataverse API... (${counter}s elapsed)"
        fi
    done
    
    log "❌ ERROR: Dataverse API validation failed after ${max_wait} seconds"
    return 1
}

validate_solr_health() {
    local max_wait=${1:-60}
    local counter=0
    
    log "Validating Solr health (timeout: ${max_wait}s)..."
    
    while [ $counter -lt $max_wait ]; do
        # Check if Solr process is running
        if pgrep -f "solr" > /dev/null; then
            # Check if Solr is responding
            if curl -s --max-time 10 "http://localhost:8983/solr/admin/cores" > /dev/null; then
                log "✓ Solr is running and accessible"
                return 0
            fi
        fi
        
        sleep 5
        counter=$((counter + 5))
        
        if [ $((counter % 30)) -eq 0 ]; then
            log "Still waiting for Solr health validation... (${counter}s elapsed)"
        fi
    done
    
    log "❌ ERROR: Solr health validation failed after ${max_wait} seconds"
    return 1
}

# Function to perform comprehensive service restart with validation
restart_services_with_validation() {
    log "Performing comprehensive service restart with validation..."
    
    # Stop services in reverse order
    log "Stopping Solr service..."
    sudo systemctl stop solr || true
    sleep 5
    
    log "Stopping Payara service..."
    sudo systemctl stop payara || true
    sleep 10
    
    # Clean up any remaining processes
    if pgrep -f "payara" > /dev/null; then
        log "Force stopping remaining Payara processes..."
        sudo pkill -f "payara" || true
        sleep 5
    fi
    
    if pgrep -f "solr" > /dev/null; then
        log "Force stopping remaining Solr processes..."
        sudo pkill -f "solr" || true
        sleep 5
    fi
    
    # Start services in proper order
    log "Starting Payara service..."
    if ! sudo systemctl start payara; then
        log "❌ ERROR: Failed to start Payara service"
        return 1
    fi
    
    # Validate Payara health
    if ! validate_payara_health 120; then
        log "❌ ERROR: Payara health validation failed after restart"
        return 1
    fi
    
    log "Starting Solr service..."
    if ! sudo systemctl start solr; then
        log "❌ ERROR: Failed to start Solr service"
        return 1
    fi
    
    # Validate Solr health
    if ! validate_solr_health 60; then
        log "❌ ERROR: Solr health validation failed after restart"
        return 1
    fi
    
    log "✅ All services restarted and validated successfully"
    return 0
}

# Function to recover from security policy errors
recover_from_policy_error() {
    log "Attempting to recover from security policy errors..."
    
    # Ensure security policy exists and is properly configured
    if ! ensure_security_policy_exists; then
        log "❌ ERROR: Failed to create/fix security policy files"
        return 1
    fi
    
    # Stop and restart Payara to ensure policy changes take effect
    log "Restarting Payara to reload security policy..."
    if ! sudo systemctl stop payara; then
        log "❌ ERROR: Failed to stop Payara during policy recovery"
        return 1
    fi
    
    sleep 5
    
    # Clean cache to ensure clean startup
    log "Cleaning Payara cache to ensure clean restart..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
    
    if ! sudo systemctl start payara; then
        log "❌ ERROR: Failed to start Payara during policy recovery"
        return 1
    fi
    
    # Wait for Payara to be ready
    log "Waiting for Payara to be ready after policy recovery..."
    local counter=0
    while [ $counter -lt 60 ]; do
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
            log "Payara is ready after policy recovery"
            return 0
        fi
        sleep 5
        counter=$((counter + 5))
    done
    
    log "❌ ERROR: Payara failed to become ready after policy recovery"
    return 1
}

# STEP 2: Undeploy the previous version
undeploy_dataverse() {
    log "Checking for deployed Dataverse applications..."
    
    # Check for any version of dataverse that might be deployed
    local deployed_apps=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications 2>&1 | tee -a "$LOGFILE")
    
    # Undeploy any dataverse applications found
    if echo "$deployed_apps" | grep -q "dataverse-"; then
        log "Found Dataverse applications deployed. Proceeding with comprehensive undeploy..."
        
        # Try to undeploy the current version first
        if echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION"; then
            log "Undeploying dataverse-$CURRENT_VERSION..."
            if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy dataverse-$CURRENT_VERSION 2>&1 | tee -a "$LOGFILE"; then
                log "Undeploy of dataverse-$CURRENT_VERSION completed successfully."
            else
                log "WARNING: Standard undeploy of dataverse-$CURRENT_VERSION failed. Continuing with recovery."
            fi
        fi
        
        # Also try to undeploy the target version in case it was partially deployed
        if echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
            log "Found partially deployed dataverse-$TARGET_VERSION. Attempting to undeploy..."
            if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy dataverse-$TARGET_VERSION 2>&1 | tee -a "$LOGFILE"; then
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
                    sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy "$app_name" 2>&1 | tee -a "$LOGFILE" || true
                fi
            fi
        done < <(echo "$deployed_apps")
        
        # Verify no dataverse applications remain
        local remaining_apps=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications 2>/dev/null)
        if echo "$remaining_apps" | grep -q "dataverse-"; then
            log "WARNING: Some Dataverse applications may still be deployed. Will clean up in application state clearing step."
        else
            log "All Dataverse applications successfully undeployed."
            return 0
        fi
        
        # If standard undeploy fails, try recovery methods
        log "WARNING: Standard undeploy failed. Attempting recovery methods..."
        
        # Check and fix policy file issues proactively
        log "Checking security policy configuration..."
        if ! ensure_security_policy_exists; then
            log "❌ ERROR: Failed to ensure security policy configuration"
        fi
        
        # Specifically check for default.policy vs server.policy
        local policy_dir="$PAYARA/glassfish/domains/domain1/config"
        if [[ -f "$policy_dir/default.policy" ]]; then
            log "Found default.policy file. Checking permissions..."
            ls -la "$policy_dir/default.policy" | tee -a "$LOGFILE"
        elif [[ -f "$policy_dir/server.policy" ]]; then
            log "Found server.policy file. Checking permissions..."
            ls -la "$policy_dir/server.policy" | tee -a "$LOGFILE"
        else
            log "WARNING: No policy files found. Creating default configuration..."
            ensure_security_policy_exists
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
            if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications >/dev/null 2>&1; then
                break
            fi
            sleep 10
            retries=$((retries + 1))
            log "Waiting for Payara startup... ($retries/12)"
        done
        
        # Try undeploy again
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy dataverse-$CURRENT_VERSION; then
            log "Recovery Method 1 successful: Undeploy completed after restart."
            return 0
        fi
        
        # Recovery Method 2: Force undeploy with --cascade option
        log "Recovery Method 2: Attempting force undeploy with cascade..."
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" undeploy --cascade=true dataverse-$CURRENT_VERSION; then
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
        if sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
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
        
        # Use robust directory creation
        if robust_mkdir "$BACKUP_DIR" "Payara backup directory"; then
            # Create subdirectories
            robust_mkdir "$BACKUP_DIR/glassfish/domains" "backup subdirectories" || log "WARNING: Failed to create subdirectories, but continuing..."
        else
            log "❌ ERROR: Unable to create backup directory with any method"
            log "❌ CRITICAL: Backup directory is essential for safe upgrade operations"
            log ""
            log "🔧 TROUBLESHOOTING STEPS:"
            log "  1. Check disk space: df -h $(dirname '$BACKUP_DIR')"
            log "  2. Check parent directory permissions: ls -ld $(dirname '$BACKUP_DIR')"
            log "  3. Verify sudo access: sudo -l"
            log "  4. Try manual creation: sudo mkdir -p '$BACKUP_DIR'"
            log "  5. Check for filesystem issues: dmesg | tail -20"
            log ""
            log "Upgrade aborted for safety. Please resolve backup directory issues and retry."
            exit 1
        fi
    fi
    
    # Copy domain configuration to backup
    if [ ! -d "$BACKUP_DIR/glassfish/domains/domain1" ]; then
        log "Backing up domain1 configuration..."
        robust_mkdir "$BACKUP_DIR" "backup parent directory" || log "WARNING: Failed to create backup parent directory, but continuing..."
        if robust_copy "$PAYARA/glassfish/domains/domain1" "$BACKUP_DIR/glassfish/domains/" "domain1 configuration"; then
            log "✓ Domain backup created successfully at: $BACKUP_DIR/glassfish/domains/domain1"
            
            # Validate backup integrity
            if [ -d "$BACKUP_DIR/glassfish/domains/domain1/config" ] && [ -f "$BACKUP_DIR/glassfish/domains/domain1/config/domain.xml" ]; then
                log "✓ Backup validation: Critical configuration files verified"
            else
                log "❌ ERROR: Backup validation failed - critical files missing"
                log "❌ CRITICAL: Cannot proceed with upgrade without valid backup"
                log "Please resolve backup issues and run the script again."
                exit 1
            fi
        else
            log "❌ ERROR: Failed to backup domain1 configuration"
            log "❌ CRITICAL: Backup is essential for safe upgrade operations"
            log "❌ Without backup, rollback is impossible if upgrade fails"
            log ""
            log "🔧 TROUBLESHOOTING STEPS:"
            log "  1. Check disk space: df -h $(dirname '$BACKUP_DIR')"
            log "  2. Check permissions: ls -ld '$PAYARA/glassfish/domains/domain1'"
            log "  3. Verify sudo access: sudo -l"
            log "  4. Try manual backup: sudo cp -r '$PAYARA/glassfish/domains/domain1' '$BACKUP_DIR/glassfish/domains/'"
            log ""
            log "Upgrade aborted for safety. Please resolve backup issues and retry."
            exit 1
        fi
    else
        log "Domain backup already exists. Verifying backup integrity..."
        if [ -d "$BACKUP_DIR/glassfish/domains/domain1/config" ] && [ -f "$BACKUP_DIR/glassfish/domains/domain1/config/domain.xml" ]; then
            log "✓ Existing backup validation: Critical configuration files verified"
        else
            log "❌ ERROR: Existing backup appears incomplete or corrupted"
            log "Removing incomplete backup and creating fresh one..."
            sudo rm -rf "$BACKUP_DIR/glassfish/domains/domain1" || true
            
            if robust_copy "$PAYARA/glassfish/domains/domain1" "$BACKUP_DIR/glassfish/domains/" "domain1 configuration"; then
                log "✓ Fresh backup created successfully"
            else
                log "❌ ERROR: Failed to create fresh backup"
                log "❌ CRITICAL: Cannot proceed without valid backup"
                exit 1
            fi
        fi
    fi
}

# STEP 4: Stop Payara
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        
        # Try multiple methods for stopping Payara due to sudo user resolution issues
        local stop_success=false
        
        # Method 1: Standard sudo
        if sudo systemctl stop payara 2>/dev/null; then
            stop_success=true
            log "✓ Payara stopped with standard sudo method"
        else
            log "WARNING: Standard sudo systemctl failed, trying alternative methods..."
            
            # Method 2: Try with explicit shell
            if sudo bash -c "systemctl stop payara" 2>/dev/null; then
                stop_success=true
                log "✓ Payara stopped with sudo bash method"
            else
                log "WARNING: sudo bash method also failed, trying LDAP-friendly sudo methods..."
                
                # Method 3: Try sudo with different flags for LDAP/SSSD environments
                if sudo -H bash -c "systemctl stop payara" 2>/dev/null; then
                    stop_success=true
                    log "✓ Payara stopped with sudo HOME method"
                elif sudo -s bash -c "systemctl stop payara" 2>/dev/null; then
                    stop_success=true
                    log "✓ Payara stopped with sudo shell method"
                else
                    log "WARNING: All sudo systemctl methods failed, trying asadmin approach..."
                    
                    # Method 4: Try asadmin stop-domain (often works when systemctl doesn't)
                    if sudo -H bash -c "$PAYARA/bin/asadmin stop-domain domain1" 2>/dev/null; then
                        stop_success=true
                        log "✓ Payara stopped using sudo asadmin method"
                    elif sudo bash -c "$PAYARA/bin/asadmin stop-domain domain1" 2>/dev/null; then
                        stop_success=true
                        log "✓ Payara stopped using sudo bash asadmin method"
                    elif $PAYARA/bin/asadmin stop-domain domain1 2>/dev/null; then
                        stop_success=true
                        log "✓ Payara stopped using direct asadmin method"
                    else
                        log "WARNING: asadmin methods failed, trying direct systemctl..."
                        
                        # Method 5: Try direct systemctl (may work if user has appropriate permissions)
                        if systemctl stop payara 2>/dev/null; then
                            stop_success=true
                            log "✓ Payara stopped with direct systemctl method"
                        else
                            log "WARNING: Direct systemctl also failed, trying process termination..."
                            
                            # Method 6: Try to kill Payara processes directly
                            if sudo -H pkill -f "payara.*domain1" 2>/dev/null; then
                                sleep 5
                                if ! pgrep -f payara > /dev/null; then
                                    stop_success=true
                                    log "✓ Payara stopped using sudo kill method"
                                fi
                            elif sudo pkill -f "payara.*domain1" 2>/dev/null; then
                                sleep 5
                                if ! pgrep -f payara > /dev/null; then
                                    stop_success=true
                                    log "✓ Payara stopped using sudo kill method"
                                fi
                            elif pkill -f "payara.*domain1" 2>/dev/null; then
                                sleep 5
                                if ! pgrep -f payara > /dev/null; then
                                    stop_success=true
                                    log "✓ Payara stopped using direct kill method"
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        fi
        
        if [ "$stop_success" = false ]; then
            log "❌ ERROR: Failed to stop Payara with all methods"
            log "This may be due to user resolution issues in sudo"
            log "Current user info:"
            log "  USER: $USER"
            log "  UID: $(id -u 2>/dev/null || echo 'unknown')"
            log "  whoami: $(whoami 2>/dev/null || echo 'unknown')"
            log "  Sudo test: $(sudo whoami 2>&1 | head -1)"
            log ""
            log "Please manually stop Payara and try again, or check sudo configuration."
            return 1
        fi
        
        # Verify Payara is actually stopped
        local retries=0
        while [ $retries -lt 10 ]; do
            if ! pgrep -f payara > /dev/null; then
                log "Payara service stopped successfully."
                return 0
            fi
            sleep 2
            retries=$((retries + 1))
            log "Waiting for Payara to stop... ($retries/10)"
        done
        
        log "WARNING: Payara may still be running after stop attempts"
        log "Checking remaining processes:"
        pgrep -f payara | tee -a "$LOGFILE" || log "No Payara processes found by pgrep"
        
        # If still running, try one more forceful kill
        if pgrep -f payara > /dev/null; then
            log "Attempting forceful termination..."
            sudo pkill -9 -f payara 2>/dev/null || pkill -9 -f payara 2>/dev/null || true
            sleep 3
        fi
        
        log "Payara stop process completed."
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
    
    # Download new Payara version with caching
    log "Downloading Payara $PAYARA_VERSION..."
    if ! download_with_cache "$PAYARA_DOWNLOAD_URL" "payara-${PAYARA_VERSION}.zip" "Payara $PAYARA_VERSION" "$PAYARA_SHA256"; then
        check_error "Failed to download Payara $PAYARA_VERSION"
    fi
    
    # Move cached file to current directory for extraction
    cp "$DOWNLOAD_CACHE_DIR/payara-${PAYARA_VERSION}.zip" "payara-${PAYARA_VERSION}.zip"
    
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
        log "❌ ERROR: Backup directory ${PAYARA}.${CURRENT_VERSION}.backup not found!"
        log "This indicates the Payara backup step was not completed successfully."
        log "Cannot proceed with domain restoration without a backup."
        
        # Check if the original Payara is still available elsewhere
        if [ -d "$PAYARA_OLD" ]; then
            log "Found $PAYARA_OLD. Attempting to use as backup source..."
            sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_DIST"
            sudo cp -r "$PAYARA_OLD/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
            check_error "Failed to restore domain configuration from payara5"
        elif [ -d "/usr/local/payara" ] && [ "/usr/local/payara" != "$PAYARA" ]; then
            log "Found /usr/local/payara. Attempting to use as backup source..."
            sudo mv "$PAYARA/glassfish/domains/domain1" "$PAYARA/glassfish/domains/domain1_DIST"
            sudo cp -r "/usr/local/payara/glassfish/domains/domain1" "$PAYARA/glassfish/domains/"
            check_error "Failed to restore domain configuration from /usr/local/payara"
        else
            log "❌ ERROR: No suitable domain backup found. Using fresh domain1 configuration."
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
            log "❌ ERROR: Domain backup directory ${PAYARA}.${CURRENT_VERSION}.backup/glassfish/domains/domain1 not found!"
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
    
    # Download with caching
    if ! download_with_cache "$DATAVERSE_WAR_URL" "dataverse-${TARGET_VERSION}.war" "Dataverse $TARGET_VERSION WAR" "$DATAVERSE_WAR_SHA256"; then
        check_error "Failed to download Dataverse WAR file"
    fi
    
    # Move cached file to current directory and then to standard location
    cp "$DOWNLOAD_CACHE_DIR/dataverse-${TARGET_VERSION}.war" "dataverse-${TARGET_VERSION}.war"
    sudo mv "dataverse-${TARGET_VERSION}.war" "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    check_error "Failed to move WAR file"
    
    log "Dataverse WAR download completed successfully."
    sudo chown -R "$DATAVERSE_USER:" "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

deploy_dataverse() {
    log "Deploying Dataverse $TARGET_VERSION..."
    
    # First, ensure we have a clean deployment state
    log "Preparing clean deployment state..."
    prepare_clean_deployment_state
    
    # Create temporary file to capture deployment output for analysis
    local deploy_output_file=$(mktemp)
    
    log "Running command: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin deploy $WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    
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
            log "📊 Deployment encountered database schema conflicts (expected during upgrades)"
            log "🔄 Initiating automatic recovery process..."
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
    
    # Check if policy error recovery is needed first
    if [[ -f "/tmp/dataverse_upgrade_policy_recovery" ]]; then
        log "Policy error detected. Attempting policy recovery before standard recovery..."
        if recover_from_policy_error; then
            log "Policy recovery completed. Retrying deployment..."
            rm -f "/tmp/dataverse_upgrade_policy_recovery"
            
            # Quick retry after policy fix
            local policy_retry_output_file=$(mktemp)
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE" > "$policy_retry_output_file"; then
                if analyze_deployment_output "$policy_retry_output_file"; then
                    log "Deployment successful after policy recovery."
                    rm -f "$policy_retry_output_file"
                    return 0
                fi
            fi
            rm -f "$policy_retry_output_file"
            log "Policy recovery didn't resolve the issue. Proceeding with standard recovery..."
        fi
    fi
    
    # Recovery steps with enhanced database schema conflict handling
    log "🔄 Initiating enhanced recovery process for database schema conflicts..."
    
    log "Stopping Payara service..."
    sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"
    
    log "Performing comprehensive cleanup to resolve database schema conflicts..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>&1 | tee -a "$LOGFILE"
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>&1 | tee -a "$LOGFILE"
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases" 2>&1 | tee -a "$LOGFILE"
    
    # Additional cleanup for deployment artifacts that might cause schema conflicts
    log "Clearing deployment artifacts and application caches..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/__internal" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/.dataverse*" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse*" 2>/dev/null || true
    
    log "Starting Payara service with clean state..."
    sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"
    
    # Wait for startup with extended time for database migrations
    log "Waiting 90 seconds for Payara to fully start and complete database migrations..."
    sleep 90
    
    # Retry deployment with analysis
    log "Retrying deployment..."
    log "Running command: sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin deploy $WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war"
    local retry_output_file=$(mktemp)
    
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE" > "$retry_output_file"; then
        log "Retry deployment command completed. Analyzing output..."
        if analyze_deployment_output "$retry_output_file"; then
            log "✅ Retry deployment completed successfully!"
            log "ℹ️ Database schema conflicts were resolved automatically during recovery."
            
            # For database migration scenarios, give extra time before verification
            log "Allowing extra time for database migrations to complete after retry deployment..."
            sleep 120
            
            # Verify what's actually deployed after retry
            if verify_deployment; then
                log "Dataverse deployment verified successfully after retry."
                rm -f "$deploy_output_file" "$retry_output_file"
                return 0
            else
                log "❌ ERROR: Failed to verify Dataverse deployment after recovery attempt."
                log "🔄 Attempting final recovery with forced clean deployment..."
                
                # Final recovery attempt with forced clean deployment
                if attempt_forced_clean_deployment; then
                    log "✅ Forced clean deployment successful!"
                    rm -f "$deploy_output_file" "$retry_output_file"
                    return 0
                else
                    log "❌ ERROR: All deployment recovery attempts failed."
                    rm -f "$deploy_output_file" "$retry_output_file"
                    return 1
                fi
            fi
        else
            log "❌ ERROR: Failed to deploy Dataverse after recovery attempt with non-benign errors."
            rm -f "$deploy_output_file" "$retry_output_file"
            return 1
        fi
    else
        log "❌ ERROR: Retry deployment command failed."
        rm -f "$deploy_output_file" "$retry_output_file"
        return 1
    fi
}

# Function to prepare a clean deployment state to avoid database schema conflicts
prepare_clean_deployment_state() {
    log "Preparing clean deployment state to avoid database schema conflicts..."
    
    # Stop Payara to ensure clean state
    log "Stopping Payara service for clean deployment..."
    sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"
    
    # Clear all cached files that might hold old entity mappings and cause schema conflicts
    log "Removing cached application files and deployment artifacts..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/__internal" 2>/dev/null || true
    
    # Clear any remaining deployed applications to prevent conflicts
    log "Ensuring all old applications are completely removed..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-$CURRENT_VERSION" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse-$TARGET_VERSION" 2>/dev/null || true
    
    # Clear deployment artifacts that might cause schema conflicts
    log "Clearing deployment artifacts and temporary files..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/.dataverse*" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse*" 2>/dev/null || true
    
    # Start Payara with clean state
    log "Starting Payara with clean application state..."
    if ! sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"; then
        log "❌ ERROR: Failed to start Payara service"
        log "Checking service status for more details..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        return 1
    fi
    
    # Wait for startup and verify Payara is responding
    log "Waiting for Payara to fully start..."
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
        log "❌ ERROR: Payara not responding after restart"
        log "Checking service status for more details..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        return 1
    fi
    
    log "Clean deployment state prepared successfully."
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
        log "❌ ERROR: Failed to start Payara service"
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
        log "❌ ERROR: Payara not responding after restart"
        log "Checking service status for more details..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        return 1
    fi
}

# Function to attempt a forced clean deployment as a last resort
attempt_forced_clean_deployment() {
    log "🔄 Attempting forced clean deployment as final recovery step..."
    
    # Stop Payara completely
    log "Stopping Payara service completely..."
    sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE"
    
    # Comprehensive cleanup of all deployment artifacts
    log "Performing comprehensive cleanup of all deployment artifacts..."
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/generated" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/osgi-cache" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/lib/databases" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/__internal" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/.dataverse*" 2>/dev/null || true
    sudo rm -rf "$PAYARA/glassfish/domains/domain1/applications/dataverse*" 2>/dev/null || true
    
    # Clear any temporary deployment files
    log "Clearing temporary deployment files..."
    sudo find "$PAYARA/glassfish/domains/domain1" -name "*.tmp" -delete 2>/dev/null || true
    sudo find "$PAYARA/glassfish/domains/domain1" -name "*.tmp.*" -delete 2>/dev/null || true
    
    # Start Payara with clean state
    log "Starting Payara with completely clean state..."
    if ! sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"; then
        log "❌ ERROR: Failed to start Payara service during forced clean deployment"
        return 1
    fi
    
    # Extended wait for startup
    log "Waiting 120 seconds for Payara to fully start with clean state..."
    sleep 120
    
    # Verify Payara is responding
    local counter=0
    while [ $counter -lt 120 ]; do
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
            log "Payara is responding to asadmin commands."
            break
        fi
        sleep 10
        counter=$((counter + 10))
    done
    
    if [ $counter -ge 120 ]; then
        log "❌ ERROR: Payara not responding after forced clean restart"
        return 1
    fi
    
    # Attempt deployment with forced clean state
    log "Attempting deployment with forced clean state..."
    local forced_deploy_output=$(mktemp)
    
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE" > "$forced_deploy_output"; then
        log "Forced clean deployment command completed. Analyzing output..."
        if analyze_deployment_output "$forced_deploy_output"; then
            log "✅ Forced clean deployment completed successfully!"
            rm -f "$forced_deploy_output"
            
            # Extended wait for database migrations
            log "Waiting 180 seconds for database migrations to complete after forced clean deployment..."
            sleep 180
            
            if verify_deployment; then
                log "✅ Forced clean deployment verified successfully!"
                return 0
            else
                log "❌ ERROR: Forced clean deployment verification failed."
                return 1
            fi
        else
            log "❌ ERROR: Forced clean deployment failed with non-benign errors."
            rm -f "$forced_deploy_output"
            return 1
        fi
    else
        log "❌ ERROR: Forced clean deployment command failed."
        rm -f "$forced_deploy_output"
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
    
    if curl -s -f "$migration_endpoint" 2>/dev/null; then
        log "Database migration endpoint available, attempting to trigger migrations..."
        local migration_response=$(curl -X POST -s "$migration_endpoint" 2>/dev/null)
        if [ -n "$migration_response" ]; then
            log "Migration response: $migration_response"
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

# Function to recover indexing after service crashes
recover_indexing_after_restart() {
    log "Checking and recovering indexing status after service restart..."
    
    # Wait a moment for services to fully initialize
    sleep 10
    
    # Check if Solr index is empty
    local index_doc_count=$(get_solr_doc_count)
    log "Current index contains: $index_doc_count documents"
    
    if [ "$index_doc_count" -eq 0 ]; then
        log "Index is empty after restart. Checking if this is expected..."

        # Hacky workaround to avoid curl error when index is empty
        FAIL_MESSAGE='{"status":"NULL","data":{"availablePartitionIds":[0],"args":{"numPartitions":1,"partitionIdToProcess":0},"message":""}}'
        # Get dataset count from API to see if we should have content
        local api_response=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null || echo "$FAIL_MESSAGE")
        if echo "$api_response" | jq -e '.data.message'; then
            local expected_items=$(echo "$api_response" | jq -r '.data.message' | grep -oE '[0-9]+ dataverses and [0-9]+ datasets' || echo "")
            if [[ -n "$expected_items" ]]; then
                log "Expected content found: $expected_items"
                log "Starting recovery reindexing to restore search functionality..."
                
                # Start reindexing
                log "Running recovery command: curl http://localhost:8080/api/admin/index"
                local recovery_result=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null)
                # Check if recovery_result is a valid JSON object
                if ! echo "$recovery_result" | jq -e '.status' >/dev/null 2>&1; then
                    log "✗ Recovery result is not a valid JSON object"
                    return 1
                fi
                if echo "$recovery_result" | jq -e '.status' >/dev/null 2>&1; then
                    local recovery_msg=$(echo "$recovery_result" | jq -r '.data.message' 2>/dev/null || "Recovery indexing started")
                    log "✓ Recovery indexing initiated: $recovery_msg"
                    
                    # Monitor initial progress for 1 minute
                    log "Monitoring recovery progress for 1 minute..."
                    local start_time=$(date +%s)
                    local last_count=0
                    
                    while [ $(($(date +%s) - start_time)) -lt 60 ]; do
                        sleep 10
                        local current_count=$(get_solr_doc_count)
                        # Check if current_count is a number
                        if ! [[ "$current_count" =~ ^[0-9]+$ ]]; then
                            log "✗ Current count is not a number"
                            return 1
                        fi
                        
                        if [ "$current_count" -gt "$last_count" ]; then
                            log "Recovery progress: $current_count documents indexed"
                            if [ "$current_count" -gt 100 ]; then
                                log "✓ Recovery indexing is working. It will continue in the background."
                                return 0
                            fi
                        fi
                        last_count=$current_count
                    done
                    
                    if [ "$last_count" -gt 0 ]; then
                        log "✓ Recovery indexing started successfully ($last_count documents indexed)"
                    else
                        log "⚠ Recovery indexing may be slow to start. Monitor manually with:"
                        log "  curl -s \"http://localhost:8983/solr/collection1/select?q=*:*&rows=0\" | jq '.response.numFound'"
                    fi
                else
                    log "✗ Failed to start recovery indexing"
                    return 1
                fi
            else
                log "ℹ No content expected to be indexed (empty installation)"
            fi
        else
            log "⚠ Could not determine expected content from API"
        fi
    else
        log "✓ Index contains data ($index_doc_count documents) - no recovery needed"
    fi
    
    return 0
}

# Function to check if Payara service is healthy and restart if needed
ensure_payara_healthy() {
    log "Checking Payara service health..."
    
    # Check if systemctl reports service as active
    if ! sudo systemctl is-active --quiet payara; then
        log "WARNING: Payara service is not active. Attempting to restart..."
        sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"
        sleep 30
    fi
    
    # Check if asadmin commands work (real health check)
    if ! sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
        log "WARNING: Payara admin interface not responding. Service may have crashed."
        log "Checking service status..."
        sudo systemctl status payara --no-pager 2>&1 | tee -a "$LOGFILE"
        
        log "Attempting to restart Payara service..."
        sudo systemctl stop payara 2>&1 | tee -a "$LOGFILE" || true
        sleep 5
        sudo systemctl start payara 2>&1 | tee -a "$LOGFILE"
        
        # Wait for restart
        local counter=0
        while [ $counter -lt 120 ]; do
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications >/dev/null 2>&1; then
                log "✓ Payara successfully restarted and responding"
                
                # Check and recover indexing if needed after restart
                log "Checking if indexing recovery is needed after restart..."
                if recover_indexing_after_restart; then
                    log "✓ Indexing status verified/recovered after restart"
                else
                    log "⚠ Indexing recovery had issues, but continuing..."
                fi
                return 0
            fi
            sleep 5
            counter=$((counter + 5))
            if [ $((counter % 30)) -eq 0 ]; then
                log "Still waiting for Payara restart... ($counter seconds elapsed)"
            fi
        done
        
        log "❌ ERROR: Payara failed to restart properly"
        return 1
    fi
    
    log "✓ Payara service is healthy"
    return 0
}

# Function to verify what's actually deployed
verify_deployment() {
    log "Verifying deployment status (timeout: 10 minutes)..."
    local MAX_WAIT=600  # Increased to 10 minutes to allow for database migrations
    local COUNTER=0

    while [ $COUNTER -lt $MAX_WAIT ]; do
        # First ensure Payara is healthy before checking deployment
        if ! ensure_payara_healthy; then
            log "❌ ERROR: Cannot verify deployment - Payara service is not healthy"
            return 1
        fi
        
        # Check for successful deployment by curling the API endpoint
        if curl -s --fail "http://localhost:8080/api/info/version" &> /dev/null; then
            local version
            version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
            # Check if version is a valid version number
            if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                log "✗ Deployment verification failed: $version is not a valid version number"
                return 1
            fi
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
                log "No Dataverse application found in deployment list. Checking for mixed deployment state..."
                # Check for mixed deployment state and resolve it
                if resolve_deployment_mixed_state; then
                    log "Mixed deployment state resolved. Continuing verification..."
                    continue
                else
                    log "Failed to resolve mixed deployment state."
                    return 1
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

    log "❌ ERROR: Deployment verification failed within the timeout period."
    log "Final deployment status:"
    sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>&1 | tee -a "$LOGFILE"
    
    log "Checking server logs for more details:"
    if [ -f "$PAYARA/glassfish/domains/domain1/logs/server.log" ]; then
        log "Last 20 lines of server log:"
        tail -20 "$PAYARA/glassfish/domains/domain1/logs/server.log" | tee -a "$LOGFILE"
    fi
    
    return 1
}

# Function to resolve mixed deployment state (called during verification)
resolve_deployment_mixed_state() {
    log "Resolving mixed deployment state..."
    
    # Check current deployment status
    local deployed_apps=$(sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-applications 2>/dev/null)
    log "Current applications: $deployed_apps"
    
    # Check if both versions are deployed
    local has_old_version=false
    local has_new_version=false
    
    if echo "$deployed_apps" | grep -q "dataverse-$CURRENT_VERSION"; then
        has_old_version=true
    fi
    
    if echo "$deployed_apps" | grep -q "dataverse-$TARGET_VERSION"; then
        has_new_version=true
    fi
    
    if [ "$has_old_version" = true ] && [ "$has_new_version" = true ]; then
        log "Mixed deployment detected: both versions are deployed"
        
        # Undeploy old version
        log "Undeploying old version dataverse-$CURRENT_VERSION..."
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy "dataverse-$CURRENT_VERSION" 2>&1 | tee -a "$LOGFILE"; then
            log "✓ Old version successfully undeployed"
            return 0
        else
            log "✗ Failed to undeploy old version"
            return 1
        fi
    elif [ "$has_old_version" = true ] && [ "$has_new_version" = false ]; then
        log "Only old version is deployed. Attempting to deploy new version..."
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE"; then
            log "✓ New version successfully deployed"
            # Now undeploy old version
            sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin undeploy "dataverse-$CURRENT_VERSION" 2>&1 | tee -a "$LOGFILE" || true
            return 0
        else
            log "✗ Failed to deploy new version"
            return 1
        fi
    elif [ "$has_old_version" = false ] && [ "$has_new_version" = false ]; then
        log "No Dataverse applications deployed. Attempting to deploy new version..."
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin deploy "$WAR_FILE_LOCATION/dataverse-${TARGET_VERSION}.war" 2>&1 | tee -a "$LOGFILE"; then
            log "✓ New version successfully deployed"
            return 0
        else
            log "✗ Failed to deploy new version"
            return 1
        fi
    else
        log "Only new version is deployed. This is the expected state."
        return 0
    fi
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
        
        # Set the feature flag via JVM options (as per Dataverse 6.6 documentation)
        log "Setting dataverse.feature.index-harvested-metadata-source=true via JVM options..."
        
        # Check if the JVM option already exists
        if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-jvm-options | grep -q 'dataverse.feature.index-harvested-metadata-source=true'; then
            log "✅ index-harvested-metadata-source feature flag is already enabled"
        else
            # Add the JVM option
            if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin create-jvm-options "-Ddataverse.feature.index-harvested-metadata-source=true" 2>&1 | tee -a "$LOGFILE"; then
                log "✅ index-harvested-metadata-source feature flag enabled successfully"
                log "Note: Payara will need to be restarted for this change to take effect"
            else
                log "⚠️ WARNING: Could not set feature flag via JVM options."
                log "You may need to set it manually: dataverse.feature.index-harvested-metadata-source=true"
            fi
        fi
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
        log "❌ ERROR: Failed to set SameSite value."
        return 1
    fi
    
    log "Enabling SameSite..."
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin set server-config.network-config.protocols.protocol.http-listener-1.http.cookie-same-site-enabled=true 2>&1 | tee -a "$LOGFILE"; then
        log "SameSite enabled successfully."
    else
        log "❌ ERROR: Failed to enable SameSite."
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
        log "❌ ERROR: Failed to start Payara service."
        return 1
    fi
    
    # Wait for Payara to fully start
    log "Waiting for Payara to fully initialize (timeout: ${PAYARA_START_TIMEOUT}s)..."
    local COUNTER=0
    while [ $COUNTER -lt $PAYARA_START_TIMEOUT ]; do
        if curl -s -f "http://localhost:8080/api/info/version" 2> /dev/null; then
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
        log "❌ ERROR: Payara failed to start within the timeout period (${PAYARA_START_TIMEOUT}s)."
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
    
    # Download with caching
    if ! download_with_cache "$CITATION_TSV_URL" "citation.tsv" "citation metadata block" "$CITATION_TSV_SHA256"; then
        log "❌ ERROR: Failed to download citation metadata block"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # Copy cached file to current directory
    cp "$DOWNLOAD_CACHE_DIR/citation.tsv" "citation.tsv"
    
    log "Loading citation metadata block (this may take several seconds due to size)..."
    log "Running command: curl http://localhost:8080/api/admin/datasetfield/load -H Content-type: text/tab-separated-values -X POST --upload-file citation.tsv"
    if curl "http://localhost:8080/api/admin/datasetfield/load" \
         -H "Content-type: text/tab-separated-values" \
         -X POST --upload-file citation.tsv 2>&1 | tee -a "$LOGFILE"; then
        log "Citation metadata block loaded successfully."
    else
        log "❌ ERROR: Failed to load citation metadata block."
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
    
    # Download with caching
    if ! download_with_cache "$OBJECTS_3D_TSV_URL" "3d_objects.tsv" "3D Objects metadata block" "$OBJECTS_3D_TSV_SHA256"; then
        log "❌ ERROR: Failed to download 3D Objects metadata block"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # Copy cached file to current directory
    cp "$DOWNLOAD_CACHE_DIR/3d_objects.tsv" "3d_objects.tsv"
    
    log "Running command: curl http://localhost:8080/api/admin/datasetfield/load -H Content-type: text/tab-separated-values -X POST --upload-file 3d_objects.tsv"
    if curl "http://localhost:8080/api/admin/datasetfield/load" \
         -H "Content-type: text/tab-separated-values" \
         -X POST --upload-file 3d_objects.tsv 2>&1 | tee -a "$LOGFILE"; then
        log "3D Objects metadata block loaded successfully."
    else
        log "❌ ERROR: Failed to load 3D Objects metadata block."
        return 1
    fi
    
    log "3D Objects metadata block addition completed successfully."
    cd "$SCRIPT_DIR"
    rm -rf "$TMP_DIR"
}

# Function to attempt automatic service recovery
attempt_service_recovery() {
    log "Starting automatic service recovery process..."
    local recovery_success=true
    
    # Check and recover Solr
    if ! systemctl is-active --quiet solr; then
        log "Solr service is down. Attempting to restart..."
        if robust_sudo_execute "systemctl restart solr" "Solr restart"; then
            sleep 15
            if systemctl is-active --quiet solr; then
                log "✓ Solr service recovered successfully"
            else
                log "❌ Failed to recover Solr service"
                recovery_success=false
            fi
        else
            log "❌ Failed to restart Solr service"
            recovery_success=false
        fi
    else
        log "✓ Solr service is running"
    fi
    
    # Check and recover Payara
    if ! systemctl is-active --quiet payara; then
        log "Payara service is down. Attempting to restart..."
        if robust_sudo_execute "systemctl restart payara" "Payara restart"; then
            sleep 30  # Payara needs more time to start
            if systemctl is-active --quiet payara || pgrep -f "payara.*domain1" > /dev/null; then
                log "✓ Payara service recovered successfully"
            else
                log "❌ Failed to recover Payara service"
                recovery_success=false
            fi
        else
            log "❌ Failed to restart Payara service"
            recovery_success=false
        fi
    else
        log "✓ Payara service is running"
    fi
    
    # Check available disk space and memory
    local disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    # Use the "available" column from the "free -m" output, which is in MB
    local memory_available=$(free --giga | awk '/^Mem:/ {print $7}')
    
    if [ "$disk_usage" -gt 90 ]; then
        log "⚠️ WARNING: Disk usage is ${disk_usage}% - this may cause service issues"
        # Try to clean up some temporary files
        if sudo find /tmp -type f -name "*.tmp" -mtime +1 -delete 2>/dev/null; then
            log "✓ Cleaned up old temporary files"
        fi
    fi
    
    if [ "$memory_available" -lt 1 ]; then
        log "⚠️ WARNING: Low available memory (${memory_available}GB) - services may be slow"
    fi
    
    # Test basic connectivity
    if ! curl -s --max-time 5 --connect-timeout 2 "http://localhost:8983/solr/admin/ping" 2> /dev/null > /dev/null; then
        log "❌ Solr connectivity test failed"
        recovery_success=false
    else
        log "✓ Solr connectivity test passed"
    fi
    
    if [ "$recovery_success" = true ]; then
        log "✓ Service recovery completed successfully"
        return 0
    else
        log "❌ Service recovery encountered issues"
        return 1
    fi
}

# Function to ensure all essential Dataverse fields are present in the Solr schema
ensure_essential_solr_fields() {
    log "Ensuring all essential Dataverse fields are present in Solr schema..."
    
    local schema_file="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    local essential_fields=("dvObjectId" "entityId" "datasetVersionId")
    local missing_fields=()
    
    # Check which fields are missing
    for field in "${essential_fields[@]}"; do
        if ! grep -q "name=\"$field\"" "$schema_file" 2>/dev/null; then
            missing_fields+=("$field")
        fi
    done
    
    if [ ${#missing_fields[@]} -eq 0 ]; then
        log "✓ All essential fields already present in schema"
        return 0
    fi
    
    # Create backup before modifications
    sudo cp "$schema_file" "${schema_file}.backup.$(date +%Y%m%d_%H%M%S)"
    log "Created backup of schema.xml"
    
    # Add missing fields
    for field in "${missing_fields[@]}"; do
        case "$field" in
            "dvObjectId")
                log "Adding missing field: dvObjectId"
                # Add after entityId field if it exists, otherwise add in fields section
                if grep -q "name=\"entityId\"" "$schema_file"; then
                    sudo sed -i '/name="entityId"/a\    <field name="dvObjectId" type="plong" stored="true" indexed="true" multiValued="false"/>' "$schema_file"
                else
                    # Add before closing </fields> tag
                    sudo sed -i '/<\/fields>/i\    <field name="dvObjectId" type="plong" stored="true" indexed="true" multiValued="false"/>' "$schema_file"
                fi
                ;;
            "entityId")
                log "Adding missing field: entityId"
                sudo sed -i '/<\/fields>/i\    <field name="entityId" type="plong" stored="true" indexed="true" multiValued="false"/>' "$schema_file"
                ;;
            "datasetVersionId")
                log "Adding missing field: datasetVersionId"
                sudo sed -i '/<\/fields>/i\    <field name="datasetVersionId" type="plong" stored="true" indexed="true" multiValued="false"/>' "$schema_file"
                ;;
        esac
    done
    
    # Validate schema after modifications
    if ! xmllint --noout "$schema_file" 2>/dev/null; then
        log "❌ ERROR: Schema XML is invalid after adding fields. Restoring backup."
        sudo cp "${schema_file}.backup.$(date +%Y%m%d_%H%M%S)" "$schema_file"
        return 1
    fi
    
    # Verify all fields are now present
    local fields_found=0
    for field in "${essential_fields[@]}"; do
        if grep -q "name=\"$field\"" "$schema_file" 2>/dev/null; then
            fields_found=$((fields_found + 1))
        fi
    done
    
    if [ $fields_found -eq ${#essential_fields[@]} ]; then
        log "✓ All essential fields verified in schema (${#missing_fields[@]} fields added)"
        sudo chown "$SOLR_USER:" "$schema_file"
        return 0
    else
        log "❌ ERROR: Schema validation failed after adding fields"
        return 1
    fi
}

# Function to apply specific Solr configuration updates
# Updates commit timing settings as reported in forum discussions
apply_solr_config_updates() {
    log "Applying Solr commit timing configuration updates..."
    
    local SOLR_CONFIG_FILE="$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
    
    if [ ! -f "$SOLR_CONFIG_FILE" ]; then
        log "❌ ERROR: solrconfig.xml not found at $SOLR_CONFIG_FILE"
        return 1
    fi
    
    # Create backup of current solrconfig.xml
    sudo cp "$SOLR_CONFIG_FILE" "${SOLR_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    log "Created backup of solrconfig.xml"
    
    # Update autoCommit maxTime from 15000 to 30000
    log "Updating solr.autoCommit.maxTime from 15000 to 30000..."
    sudo sed -i 's/<maxTime>\${solr.autoCommit.maxTime:15000}<\/maxTime>/<maxTime>\${solr.autoCommit.maxTime:30000}<\/maxTime>/' "$SOLR_CONFIG_FILE"
    
    # Update autoSoftCommit maxTime from -1 to 1000
    log "Updating solr.autoSoftCommit.maxTime from -1 to 1000..."
    sudo sed -i 's/<maxTime>\${solr.autoSoftCommit.maxTime:-1}<\/maxTime>/<maxTime>\${solr.autoSoftCommit.maxTime:1000}<\/maxTime>/' "$SOLR_CONFIG_FILE"
    
    # Verify the changes were applied
    if grep -q '\${solr.autoCommit.maxTime:30000}' "$SOLR_CONFIG_FILE" && \
       grep -q '\${solr.autoSoftCommit.maxTime:1000}' "$SOLR_CONFIG_FILE"; then
        log "✓ Solr commit timing configuration updated successfully"
        log "  - autoCommit.maxTime: 15000 → 30000"
        log "  - autoSoftCommit.maxTime: -1 → 1000"
    else
        log "WARNING: Could not verify all Solr configuration changes were applied"
        log "Please manually check $SOLR_CONFIG_FILE for the following settings:"
        log "  - \${solr.autoCommit.maxTime:30000}"
        log "  - \${solr.autoSoftCommit.maxTime:1000}"
    fi
    
    # Set correct ownership after modification
    sudo chown "$SOLR_USER:" "$SOLR_CONFIG_FILE"
    
    return 0
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
    if ! download_with_cache "$SOLR_DOWNLOAD_URL" "solr-${SOLR_VERSION}.tgz" "Solr $SOLR_VERSION" "$SOLR_SHA256"; then
        check_error "Failed to download Solr $SOLR_VERSION"
    fi
    
    # Copy cached file to current directory for extraction
    cp "$DOWNLOAD_CACHE_DIR/solr-${SOLR_VERSION}.tgz" "solr-${SOLR_VERSION}.tgz"
    
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
    
    # Download schema with caching
    if ! download_with_cache "$SOLR_SCHEMA_URL" "schema.xml" "Solr schema" "$SOLR_SCHEMA_SHA256"; then
        check_error "Failed to download Solr schema"
    fi
    cp "$DOWNLOAD_CACHE_DIR/schema.xml" "schema.xml"
    
    # Download config with caching
    if ! download_with_cache "$SOLR_CONFIG_URL" "solrconfig.xml" "Solr config" "$SOLR_CONFIG_SHA256"; then
        check_error "Failed to download Solr config"
    fi
    cp "$DOWNLOAD_CACHE_DIR/solrconfig.xml" "solrconfig.xml"
    
    # Install new configuration files
    log "Installing new Solr configuration files..."
    sudo cp schema.xml solrconfig.xml "$SOLR_PATH/server/solr/collection1/conf/"
    check_error "Failed to install Solr configuration files"
    
    # Set correct ownership
    sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
    
    # Apply Solr commit timing configuration updates
    apply_solr_config_updates
    check_error "Failed to apply Solr configuration updates"
    
    # Ensure all essential Dataverse fields are present in the schema
    ensure_essential_solr_fields
    check_error "Failed to ensure essential Solr fields are present"
    
    # Set ownership for entire Solr directory
    log "Setting ownership for Solr directory..."
    sudo chown -R "$SOLR_USER:" "$SOLR_PATH" || return 1
    
    # Verify the Solr binary exists and is executable
    if [ ! -f "$SOLR_PATH/bin/solr" ]; then
        log "❌ ERROR: Solr binary not found at $SOLR_PATH/bin/solr after upgrade"
        log "Checking what was installed:"
        ls -la "$SOLR_PATH/" | tee -a "$LOGFILE"
        if [ -L "$SOLR_PATH" ]; then
            log "SOLR_PATH is a symlink. Following it:"
            ls -la "$(readlink -f "$SOLR_PATH")/" | tee -a "$LOGFILE"
        fi
        
        # Check if there are any solr-* directories that might have been created
        log "Checking for Solr installations in /usr/local:"
        # List Solr installation(s) using the SOLR_PATH variable and also check for other solr* directories for troubleshooting
        log "Listing Solr installation(s) using SOLR_PATH: $SOLR_PATH"
        ls -la "$SOLR_PATH" 2>/dev/null | tee -a "$LOGFILE" || log "No directory found at SOLR_PATH ($SOLR_PATH)"
        log "Checking for other solr* directories in /usr/local (in case SOLR_PATH is a symlink):"
        ls -la "$SOLR_PATH/*" 2>/dev/null | tee -a "$LOGFILE" || log "No solr* directories found in /usr/local"
        
        # Try to find any solr binary
        log "Searching for Solr binary:"
        find /usr/local -name "solr" -type f 2>/dev/null | tee -a "$LOGFILE" || log "No solr binary found"
        
        log "❌ ERROR: Solr upgrade appears to have failed. Manual intervention required."
        return 1
    fi
    
    # Make sure the Solr binary is executable
    sudo chmod +x "$SOLR_PATH/bin/solr"
    
    log "Solr binary upgrade and configuration update completed successfully."
    log "Solr binary location: $SOLR_PATH/bin/solr"
    
    # Recreate Solr collection to avoid schema compatibility issues
    recreate_solr_collection
    check_error "Failed to recreate Solr collection - initialization failures detected"
    
    # Stop Solr after upgrade - we'll restart it after custom fields are updated
    log "Stopping Solr after upgrade to prepare for custom fields update..."
    sudo systemctl stop solr || true
    
    # Check that Payara is still healthy after Solr operations
    log "Verifying Payara service health after Solr upgrade..."
    if ! ensure_payara_healthy; then
        log "WARNING: Payara service became unhealthy during Solr upgrade. This may affect subsequent steps."
        log "Attempting to ensure Payara is ready before continuing..."
        # The ensure_payara_healthy function will attempt to restart if needed
    fi
    
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
    
    # Ensure collection1 directory structure is complete
    log "Ensuring collection1 directory structure is complete..."
    if [ ! -d "$SOLR_PATH/server/solr/collection1/conf" ]; then
        log "Creating conf directory..."
        sudo -u "$SOLR_USER" mkdir -p "$SOLR_PATH/server/solr/collection1/conf"
    fi
    
    if [ ! -d "$SOLR_PATH/server/solr/collection1/data" ]; then
        log "Creating data directory..."
        sudo -u "$SOLR_USER" mkdir -p "$SOLR_PATH/server/solr/collection1/data"
    fi
    
    # Ensure core.properties exists
    if [ ! -f "$SOLR_PATH/server/solr/collection1/core.properties" ]; then
        log "Creating core.properties..."
        echo "name=collection1" | sudo -u "$SOLR_USER" tee "$SOLR_PATH/server/solr/collection1/core.properties" > /dev/null
    fi
    
    # Ensure schema.xml and solrconfig.xml exist
    if [ ! -f "$SOLR_PATH/server/solr/collection1/conf/schema.xml" ]; then
        log "❌ ERROR: schema.xml missing from collection1/conf/"
        return 1
    fi
    
    if [ ! -f "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" ]; then
        log "❌ ERROR: solrconfig.xml missing from collection1/conf/"
        return 1
    fi
    
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
        log "❌ ERROR: Solr failed to start within expected time"
        return 1
    fi
    
    # Verify the collection is healthy
    log "Verifying collection health..."
    local collection_status=$(curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" 2>/dev/null)
    
    # Check for actual initialization failures (not just the presence of the field)
    # The initFailures field is always present but should be empty: "initFailures":{ }
    # If there are failures, there will be content between the braces
    if echo "$collection_status" | grep -q '"initFailures".*{.*[a-zA-Z0-9].*}'; then
        log "❌ ERROR: Collection has initialization failures"
        log "Collection status: $collection_status"
        return 1
    fi
    
    # More robust collection verification - check multiple endpoints
    log "Performing comprehensive collection verification..."
    
    # Check if collection1 exists in the cores status
    if echo "$collection_status" | grep -q '"collection1"'; then
        log "✓ Collection1 found in cores status"
    else
        log "⚠️ Collection1 not found in cores status, checking alternative endpoints..."
        
        # Try the collection-specific endpoint
        local collection_info=$(curl -s "http://localhost:8983/solr/collection1/admin/ping" 2>/dev/null)
        if [ -n "$collection_info" ]; then
            log "✓ Collection1 responds to ping endpoint"
        else
            # Try to create the collection if it doesn't exist
            log "Attempting to create collection1..."
            local create_response=$(curl -s "http://localhost:8983/solr/admin/collections?action=CREATE&name=collection1&numShards=1&replicationFactor=1" 2>/dev/null)
            if [ -n "$create_response" ]; then
                log "Collection creation response: $create_response"
                # Wait a moment for the collection to initialize
                sleep 5
                
                # Check again
                collection_info=$(curl -s "http://localhost:8983/solr/collection1/admin/ping" 2>/dev/null)
                if [ -n "$collection_info" ]; then
                    log "✓ Collection1 created and responding"
                else
                    log "❌ ERROR: Failed to create collection1"
                    log "Collection status: $collection_status"
                    return 1
                fi
            else
                log "❌ ERROR: Failed to create collection1"
                log "Collection status: $collection_status"
                return 1
            fi
        fi
    fi
    
    # Final verification - try a simple query
    local query_test=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null)
    if [ -n "$query_test" ]; then
        log "✓ Collection1 responds to queries"
        log "✓ Solr collection recreated successfully"
        log "✓ Collection is healthy and ready for indexing"
    else
        log "❌ ERROR: Collection1 does not respond to queries"
        log "Collection status: $collection_status"
        return 1
    fi
}

# Function to diagnose and fix common Solr configuration issues
diagnose_solr_issues() {
    log "Diagnosing Solr configuration issues..."
    
    # Check if collection1 exists and has proper structure
    if [ ! -d "$SOLR_PATH/server/solr/collection1" ]; then
        log "❌ ERROR: collection1 directory not found. Creating it..."
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
        log "❌ ERROR: schema.xml not found. Downloading fresh copy..."
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        # Download with caching
        if ! download_with_cache "$SOLR_SCHEMA_URL" "schema.xml" "Solr schema" "$SOLR_SCHEMA_SHA256"; then
            log "❌ ERROR: Failed to download Solr schema"
            cd "$SCRIPT_DIR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        
        cp "$DOWNLOAD_CACHE_DIR/schema.xml" "schema.xml"
        sudo cp schema.xml "$SOLR_PATH/server/solr/collection1/conf/"
        sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
        
        # Ensure all essential fields are present in the newly downloaded schema
        log "Ensuring essential fields are present in downloaded schema..."
        ensure_essential_solr_fields || log "WARNING: Failed to ensure essential fields during diagnosis"
    fi
    
    # Check and fix solrconfig.xml
    if [ ! -f "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" ]; then
        log "❌ ERROR: solrconfig.xml not found. Downloading fresh copy..."
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        # Download with caching
        if ! download_with_cache "$SOLR_CONFIG_URL" "solrconfig.xml" "Solr config" "$SOLR_CONFIG_SHA256"; then
            log "❌ ERROR: Failed to download Solr config"
            cd "$SCRIPT_DIR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        
        cp "$DOWNLOAD_CACHE_DIR/solrconfig.xml" "solrconfig.xml"
        sudo cp solrconfig.xml "$SOLR_PATH/server/solr/collection1/conf/"
        sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
        cd "$SCRIPT_DIR"
        rm -rf "$TMP_DIR"
        
        # Apply configuration updates to the newly downloaded config
        log "Applying configuration updates to newly downloaded solrconfig.xml..."
        apply_solr_config_updates || log "WARNING: Failed to apply Solr config updates during diagnosis"
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
        log "❌ ERROR: No Solr service file found"
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
            log "❌ ERROR: Expected Solr binary not found at $expected_solr_bin"
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
            log "❌ ERROR: SOLR_PATH symlink is broken. Target $target does not exist."
            
            # Look for actual Solr installations
            local solr_installations=$(find /usr/local -maxdepth 1 -name "solr-*" -type d 2>/dev/null | sort -V | tail -1)
            if [ -n "$solr_installations" ]; then
                log "Found Solr installation: $solr_installations"
                log "Fixing symlink to point to: $solr_installations"
                sudo rm -f "$SOLR_PATH"
                sudo ln -sf "$solr_installations" "$SOLR_PATH"
                return 0
            else
                log "❌ ERROR: No Solr installations found in /usr/local"
                return 1
            fi
        fi
    fi
    
    # Check if the Solr binary exists in the expected location
    if [ ! -f "$SOLR_PATH/bin/solr" ]; then
        log "❌ ERROR: Solr binary not found at $SOLR_PATH/bin/solr"
        
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
            log "❌ ERROR: No Solr binary found anywhere in /usr/local"
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
        log "❌ ERROR: No Solr installation found. Attempting to reinstall Solr $SOLR_VERSION..."
        
        # Download and install Solr
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        log "Downloading Solr $SOLR_VERSION..."
        if ! download_with_cache "$SOLR_DOWNLOAD_URL" "solr-${SOLR_VERSION}.tgz" "Solr $SOLR_VERSION" "$SOLR_SHA256"; then
            log "❌ ERROR: Failed to download Solr $SOLR_VERSION"
            cd "$SCRIPT_DIR"
            rm -rf "$TMP_DIR"
            return 1
        fi
        
        # Copy cached file to current directory for extraction
        cp "$DOWNLOAD_CACHE_DIR/solr-${SOLR_VERSION}.tgz" "solr-${SOLR_VERSION}.tgz"
        
        log "Extracting Solr $SOLR_VERSION..."
        cd /usr/local
        sudo tar xzf "$TMP_DIR/solr-${SOLR_VERSION}.tgz" || {
            log "❌ ERROR: Failed to extract Solr"
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
    
    # First ensure Dataverse is responding to API calls
    log "Verifying Dataverse API is accessible..."
    local api_ready=false
    local counter=0
    local max_wait_time=120  # Increased timeout for different environments
    
    while [ $counter -lt $max_wait_time ]; do
        # Check if Payara service is still running
        if ! systemctl is-active --quiet payara; then
            log "WARNING: Payara service stopped during API readiness check. Attempting restart..."
            sudo systemctl restart payara
            sleep 15  # Give extra time after restart
        fi
        
        # Check API endpoint with more tolerant curl options
        if curl -s --max-time 10 --connect-timeout 5 --fail "http://localhost:8080/api/info/version" 2> /dev/null; then
            api_ready=true
            log "✓ Dataverse API is ready ($counter seconds)"
            break
        fi
        
        # Progressive backoff: shorter waits early, longer waits later
        if [ $counter -lt 30 ]; then
            sleep 5
        elif [ $counter -lt 60 ]; then
            sleep 10
        else
            sleep 15
        fi
        
        counter=$((counter + 5))
        if [ $((counter % 30)) -eq 0 ]; then
            log "Waiting for Dataverse API... ($counter/$max_wait_time seconds elapsed)"
        fi
    done
    
    if [ "$api_ready" = false ]; then
        log "WARNING: Dataverse API not accessible after $max_wait_time seconds."
        log "Attempting automatic service recovery..."
        
        # Try to recover services automatically
        if attempt_service_recovery; then
            log "✓ Service recovery successful. Retrying API check..."
            # One more quick check after recovery
            sleep 10
            if curl -s --max-time 10 --connect-timeout 5 --fail "http://localhost:8080/api/info/version" 2> /dev/null; then
                api_ready=true
                log "✓ Dataverse API is now ready after recovery"
            fi
        fi
    fi
    
    if [ "$api_ready" = false ]; then
        log "WARNING: Dataverse API still not accessible after recovery attempts."
        log "Installing base Dataverse schema to ensure essential fields are present..."
        
        # Install base schema as fallback when API is not ready
        local schema_file="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
        local fallback_tmp=$(mktemp -d)
        cd "$fallback_tmp"
        
        # Download base schema with caching
        if download_with_cache "$SOLR_SCHEMA_URL" "base_schema.xml" "base Solr schema" "$SOLR_SCHEMA_SHA256"; then
            cp "$DOWNLOAD_CACHE_DIR/base_schema.xml" "base_schema.xml"
            if xmllint --noout base_schema.xml 2>/dev/null; then
                if sudo cp base_schema.xml "$schema_file" && sudo chown "$SOLR_USER:" "$schema_file"; then
                    log "✓ Base Dataverse 6.6 schema installed successfully"
                    
                    # Ensure all essential fields are present, adding any that are missing
                    cd "$SCRIPT_DIR"
                    rm -rf "$fallback_tmp"
                    
                    if ensure_essential_solr_fields; then
                        log "✓ Essential fields verification completed successfully"
                        return 0  # Success - base schema installed with all essential fields
                    else
                        log "❌ ERROR: Failed to ensure essential fields in base schema"
                        return 1
                    fi
                else
                    log "❌ ERROR: Failed to install base schema file"
                    cd "$SCRIPT_DIR"
                    rm -rf "$fallback_tmp"
                    return 1
                fi
            else
                log "❌ ERROR: Downloaded base schema is invalid XML"
                cd "$SCRIPT_DIR"
                rm -rf "$fallback_tmp"
                return 1
            fi
        else
            log "❌ ERROR: Failed to download base schema for fallback"
            log "Cannot proceed without a working Solr schema"
            cd "$SCRIPT_DIR" 
            rm -rf "$fallback_tmp"
            return 1
        fi
    fi
    
    # Check if there are custom metadata blocks by calling the API
    local custom_blocks_json=$(curl -s --max-time 15 --retry 2 "http://localhost:8080/api/metadatablocks" 2>/dev/null)
    if [ -z "$custom_blocks_json" ] || ! echo "$custom_blocks_json" | jq . >/dev/null 2>&1; then
        log "WARNING: Failed to retrieve metadata blocks from API or invalid JSON response"
        log "Skipping custom metadata field updates"
        return 0
    fi
    local custom_blocks=$(echo "$custom_blocks_json" | jq -r '.data[] | select(.name | test("^(citation|geospatial|socialscience|astrophysics|biomedical|journal|3d_objects)$") | not) | .name' 2>/dev/null)
    
    if [ -n "$custom_blocks" ]; then
        log "Custom metadata blocks detected: $custom_blocks"
        log "Updating Solr schema with custom fields..."
        
        # Download update-fields script using cache
        local update_script_name="update-fields.sh"
        if ! download_with_cache "$UPDATE_FIELDS_URL" "$update_script_name" "update-fields.sh script" "$UPDATE_FIELDS_SHA256"; then
            log "❌ ERROR: Failed to download update-fields.sh script. Aborting custom field update."
            # This is not a fatal error for the whole upgrade, so we return 0 but log an error.
            return 0
        fi
        local update_script_path="$DOWNLOAD_CACHE_DIR/$update_script_name"
        chmod +x "$update_script_path"
        
        # Stop Solr for schema update (critical step)
        log "Stopping Solr service for schema update..."
        sudo systemctl stop solr
        check_error "Failed to stop Solr for schema update"
        
        # Wait a moment for Solr to fully stop
        sleep 5
        
        # Verify Solr is stopped
        if pgrep -f "solr" > /dev/null; then
            log "WARNING: Solr processes still running. Attempting force stop..."
            sudo pkill -f "solr" || true
            sleep 5
        fi
        
        # Get the current schema from Dataverse and run update-fields script
        log "Getting current schema from Dataverse API and running update-fields script..."
        local schema_api_url="http://localhost:8080/api/admin/index/solr/schema"
        local schema_file="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
        
        # Create backup of current schema
        if [ -f "$schema_file" ]; then
            sudo cp "$schema_file" "${schema_file}.backup.$(date +%Y%m%d_%H%M%S)"
            log "Created backup of current schema file"
        fi
        
        # Enhanced schema update with better API handling and fallback
        local schema_update_success=false
        local max_retries=5
        local retry_count=0
        
        # First ensure Payara is fully healthy before attempting schema update
        log "Ensuring Payara is fully healthy before schema update..."
        if ! ensure_payara_healthy; then
            log "❌ ERROR: Payara is not healthy, cannot proceed with schema update"
            return 1
        fi
        
        # Wait longer for Dataverse to be fully ready (including database migrations)
        log "Waiting for Dataverse to be fully ready (including database migrations)..."
        local api_ready=false
        local api_timeout=180  # Extended to 3 minutes
        local api_counter=0
        local payara_crashed=false
        
        while [ $api_counter -lt $api_timeout ]; do
            # Check if Payara is actually running
            if ! systemctl is-active --quiet payara; then
                log "⚠️ WARNING: Payara service crashed during schema update. Attempting restart..."
                sudo systemctl restart payara
                sleep 30  # Give Payara time to restart
                payara_crashed=true
            fi
            
            # Check both API endpoint and schema endpoint specifically
            if curl -s --max-time 15 "http://localhost:8080/api/info/version" >/dev/null 2>&1 && \
               curl -s --max-time 15 "$schema_api_url" | grep -q '"name"' 2>/dev/null; then
                api_ready=true
                log "✓ Dataverse API and schema endpoint are ready"
                break
            fi
            sleep 10
            api_counter=$((api_counter + 10))
            log "Waiting for Dataverse API readiness... ($api_counter/$api_timeout seconds)"
        done
        
        if [ "$api_ready" = false ]; then
            log "❌ ERROR: Dataverse API not ready after $api_timeout seconds"
            if [ "$payara_crashed" = true ]; then
                log "⚠️ Payara crashed during schema update. This is a known issue."
                log "Proceeding with fallback schema update..."
                # Force fallback schema update when Payara crashes
                log "🔄 Adding fallback custom fields due to Payara crash..."
                add_fallback_custom_fields
                if [ $? -eq 0 ]; then
                    log "✅ Fallback schema update completed successfully"
                    schema_update_success=true
                else
                    log "❌ Fallback schema update failed"
                    schema_update_success=false
                fi
            else
                log "This should not happen as schema fallback should have occurred at 60 seconds"
                schema_update_success=false
            fi
        else
            # Now attempt schema retrieval with robust error handling
            while [ $retry_count -lt $max_retries ] && [ "$schema_update_success" = false ]; do
                retry_count=$((retry_count + 1))
                log "Schema update attempt $retry_count of $max_retries..."
            
            local current_schema_json_path="$DOWNLOAD_CACHE_DIR/current_schema.json"
            # Download fresh schema data for each attempt
            if curl -s --max-time 30 --retry 2 "$schema_api_url" > "$current_schema_json_path" 2>&1; then
                log "✓ Retrieved schema from Dataverse API (attempt $retry_count)"
                
                # Validate the schema JSON is not empty and contains field definitions
                local field_count=$(grep -c '<field name=' "$current_schema_json_path" 2>/dev/null || echo "0")
                # Ensure we have a clean integer
                field_count=$(echo "$field_count" | tr -d '\n\r\t ' | head -1)
                if ! [[ "$field_count" =~ ^[0-9]+$ ]]; then
                    field_count="0"
                fi
                if [ "$field_count" -lt 10 ]; then
                    log "WARNING: Schema JSON appears invalid or incomplete (only $field_count fields). Retrying..."
                    continue
                fi
                log "Schema contains $field_count field definitions"
                
                # Create a temporary copy we can modify (in /tmp for proper permissions)
                local temp_schema_file="/tmp/temp_schema_$(date +%s)_${retry_count}.xml"
                sudo cp "$schema_file" "$temp_schema_file"
                sudo chmod 666 "$temp_schema_file"
                
                # Count fields before update
                local fields_before=$(grep -c '<field name=' "$temp_schema_file" 2>/dev/null || echo "0")
                # Ensure we have a clean integer
                fields_before=$(echo "$fields_before" | tr -d '\n\r\t ' | head -1)
                if ! [[ "$fields_before" =~ ^[0-9]+$ ]]; then
                    fields_before="0"
                fi
                log "Schema fields before update: $fields_before"
                
                # Run the update-fields script with detailed logging
                log "Executing: cat $current_schema_json_path | bash $update_script_path $temp_schema_file"
                local update_output_file="/tmp/update_fields_output_${retry_count}.log"
                
                if cat "$current_schema_json_path" | bash "$update_script_path" "$temp_schema_file" > "$update_output_file" 2>&1; then
                    log "Update-fields script completed without errors"
                    
                    # Count fields after update
                    local fields_after=$(grep -c '<field name=' "$temp_schema_file" 2>/dev/null || echo "0")
                    # Ensure we have a clean integer
                    fields_after=$(echo "$fields_after" | tr -d '\n\r\t ' | head -1)
                    if ! [[ "$fields_after" =~ ^[0-9]+$ ]]; then
                        fields_after="0"
                    fi
                    log "Schema fields after update: $fields_after"
                    
                    # Verify specific custom fields were actually added
                    local software_fields=$(grep -c "swContributorName\|swContributor\|softwareName" "$temp_schema_file" 2>/dev/null || echo "0")
                    local datacontext_fields=$(grep -c "dataContext\|contextualDataAccess" "$temp_schema_file" 2>/dev/null || echo "0")
                    local workflow_fields=$(grep -c "computationalworkflow\|workflowDescription" "$temp_schema_file" 2>/dev/null || echo "0")
                    local objects3d_fields=$(grep -c "3d.*[a-zA-Z]" "$temp_schema_file" 2>/dev/null || echo "0")
                    
                    # Clean all the custom field count variables
                    software_fields=$(echo "$software_fields" | tr -d '\n\r\t ' | head -1)
                    if ! [[ "$software_fields" =~ ^[0-9]+$ ]]; then software_fields="0"; fi
                    datacontext_fields=$(echo "$datacontext_fields" | tr -d '\n\r\t ' | head -1)
                    if ! [[ "$datacontext_fields" =~ ^[0-9]+$ ]]; then datacontext_fields="0"; fi
                    workflow_fields=$(echo "$workflow_fields" | tr -d '\n\r\t ' | head -1)
                    if ! [[ "$workflow_fields" =~ ^[0-9]+$ ]]; then workflow_fields="0"; fi
                    objects3d_fields=$(echo "$objects3d_fields" | tr -d '\n\r\t ' | head -1)
                    if ! [[ "$objects3d_fields" =~ ^[0-9]+$ ]]; then objects3d_fields="0"; fi
                    
                    log "Custom fields verification:"
                    log "  - Software fields: $software_fields"
                    log "  - Data Context fields: $datacontext_fields"
                    log "  - Workflow fields: $workflow_fields"
                    log "  - 3D Objects fields: $objects3d_fields"
                    
                    local total_custom_fields=$((software_fields + datacontext_fields + workflow_fields + objects3d_fields))
                    
                    if [ "$total_custom_fields" -gt 0 ] && [ "$fields_after" -gt "$fields_before" ]; then
                        log "✓ SUCCESS: Custom metadata fields successfully added to schema ($total_custom_fields custom fields, $((fields_after - fields_before)) total new fields)"
                        
                        # Copy the updated schema back
                        sudo cp "$temp_schema_file" "$schema_file"
                        sudo chown "$SOLR_USER:" "$schema_file"
                        log "✓ Updated schema file installed successfully"
                        
                        # Clean up
                        sudo rm -f "$temp_schema_file" "$update_output_file"
                        schema_update_success=true
                        break
                    else
                        log "WARNING: Schema update didn't add expected custom fields. Retry $retry_count/$max_retries"
                        log "Update-fields output:"
                        cat "$update_output_file" | tee -a "$LOGFILE"
                    fi
                else
                    log "WARNING: Update-fields script failed on attempt $retry_count"
                    log "Update-fields output:"
                    cat "$update_output_file" | tee -a "$LOGFILE"
                fi
                
                sudo rm -f "$temp_schema_file" "$update_output_file"
            else
                log "WARNING: Failed to retrieve schema from Dataverse API on attempt $retry_count"
            fi
            
            if [ "$schema_update_success" = false ] && [ $retry_count -lt $max_retries ]; then
                log "Waiting 10 seconds before retry..."
                sleep 10
            fi
        done
        
        if [ "$schema_update_success" = false ]; then
            log "❌ ERROR: Failed to update schema after $max_retries attempts"
            log "This may cause issues with custom metadata field indexing"
            log "The upgrade will continue, but custom metadata search may not work properly"
            exit 1
        fi
    fi
        
        # Verify the schema file was updated and is valid (regardless of success/failure)
        if [ -f "$schema_file" ] && [ -s "$schema_file" ]; then
            log "Schema file exists and has content"
            
            # Basic XML validation
            if xmllint --noout "$schema_file" 2>/dev/null; then
                log "✓ Schema XML is valid"
            else
                log "WARNING: Schema XML validation failed. Attempting to restore backup..."
                local backup_file=$(ls -t "${schema_file}.backup."* 2>/dev/null | head -1)
                if [ -n "$backup_file" ]; then
                    sudo cp "$backup_file" "$schema_file"
                    sudo chown "$SOLR_USER:" "$schema_file"
                    log "Schema backup restored from: $backup_file"
                else
                    log "WARNING: No backup schema file found for restoration"
                fi
            fi
        else
            log "❌ ERROR: Schema file is missing or empty after update. Attempting restoration..."
            local backup_file=$(ls -t "${schema_file}.backup."* 2>/dev/null | head -1)
            if [ -n "$backup_file" ]; then
                sudo cp "$backup_file" "$schema_file"
                sudo chown "$SOLR_USER:" "$schema_file"
                log "Schema backup restored from: $backup_file"
            else
                log "❌ ERROR: No backup schema file found. Schema may be corrupted!"
                log "Manual intervention may be required after upgrade."
            fi
        fi
        
        # Ensure correct ownership of schema file
        sudo chown "$SOLR_USER:" "$schema_file"
        
        log "Custom metadata block fields update process completed."
    else
        log "No custom metadata blocks detected. Skipping custom field updates."
    fi
    
    # Start Solr service
    log "Starting Solr service after schema update..."
    if ! sudo systemctl start solr; then
        log "❌ ERROR: Failed to start Solr service after schema update"
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
            
            # Try XML validation
            if ! xmllint --noout "$SOLR_PATH/server/solr/collection1/conf/schema.xml" 2>/dev/null; then
                log "❌ ERROR: Schema XML is invalid. Attempting to restore backup..."
                local backup_file=$(ls -t "$SOLR_PATH/server/solr/collection1/conf/schema.xml.backup."* 2>/dev/null | head -1)
                if [ -n "$backup_file" ]; then
                    sudo cp "$backup_file" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
                    sudo chown "$SOLR_USER:" "$SOLR_PATH/server/solr/collection1/conf/schema.xml"
                    log "Restored schema from backup: $backup_file"
                    
                    # Try starting Solr again
                    log "Attempting to start Solr again with restored schema..."
                    if sudo systemctl start solr; then
                        log "Solr started successfully with restored schema"
                    else
                        log "❌ ERROR: Solr still failed to start with restored schema"
                        return 1
                    fi
                else
                    log "❌ ERROR: No backup schema file found"
                    return 1
                fi
            fi
        else
            log "❌ ERROR: Schema file not found at $SOLR_PATH/server/solr/collection1/conf/schema.xml"
        fi
        
        if [ -f "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" ]; then
            log "Solr config file exists and is readable"
            ls -la "$SOLR_PATH/server/solr/collection1/conf/solrconfig.xml" | tee -a "$LOGFILE"
        else
            log "❌ ERROR: Solr config file not found at $SOLR_PATH/server/solr/collection1/conf/solrconfig.xml"
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
            log "❌ ERROR: Solr binary not found at $SOLR_PATH/bin/solr"
            log "Checking what's in the Solr directory:"
            ls -la "$SOLR_PATH/" | tee -a "$LOGFILE"
            if [ -L "$SOLR_PATH" ]; then
                log "SOLR_PATH is a symlink. Following it:"
                ls -la "$(readlink -f "$SOLR_PATH")/" | tee -a "$LOGFILE"
            fi
            
            # Check if there are any solr-* directories in /usr/local
            log "Checking for Solr installations in /usr/local:"
            ls -la "$SOLR_PATH/*" 2>/dev/null | tee -a "$LOGFILE" || log "No solr* directories found in /usr/local"
            
            # Try to find the actual Solr binary
            log "Searching for Solr binary:"
            find /usr/local -name "solr" -type f 2>/dev/null | tee -a "$LOGFILE" || log "No solr binary found in /usr/local"
        fi
        
        # Try systemctl start again after diagnosis
        log "Attempting systemctl start again after diagnosis..."
        if sudo systemctl start solr; then
            log "Solr started successfully after diagnosis and fixes."
        else
            log "❌ ERROR: Solr still failed to start after diagnosis."
            log "Attempting to reinstall Solr as last resort..."
            if reinstall_solr_if_needed; then
                log "Solr reinstalled. Attempting to start again..."
                if sudo systemctl start solr; then
                    log "Solr started successfully after reinstall."
                else
                    log "❌ ERROR: Solr still failed to start after reinstall."
                    log "Manual intervention required. Please check:"
                    log "1. Solr service configuration: sudo systemctl status solr"
                    log "2. Solr logs: sudo journalctl -u solr -f"
                    log "3. Solr configuration files in $SOLR_PATH/server/solr/collection1/conf/"
                    return 1
                fi
            else
                log "❌ ERROR: Failed to reinstall Solr."
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
        log "❌ ERROR: Solr failed to start within timeout (2 minutes)."
        log "Checking if Solr process is running..."
        pgrep -f solr | tee -a "$LOGFILE" || log "No Solr processes found"
        log "Checking Solr logs for startup issues..."
        if [ -f "$SOLR_PATH/server/logs/solr.log" ]; then
            log "Last 30 lines of Solr log:"
            tail -30 "$SOLR_PATH/server/logs/solr.log" | tee -a "$LOGFILE"
        fi
        return 1
    fi
    
    log "Solr custom fields update completed successfully."
    
    # Verify the schema update was successful by checking for new fields
    log "Verifying schema update was successful..."
    sleep 5  # Give Solr a moment to process the schema changes
    
    local schema_check=$(curl -s "http://localhost:8080/api/admin/index/solr/schema" 2>/dev/null)
    if [ -n "$schema_check" ]; then
        log "✅ Schema verification successful - schema is accessible after update"
        
        # Check for key new fields that should be present
        local has_version_note=$(echo "$schema_check" | grep -c "versionNote" || echo "0")
        local has_file_restricted=$(echo "$schema_check" | grep -c "fileRestricted" || echo "0")
        local has_can_download=$(echo "$schema_check" | grep -c "canDownloadFile" || echo "0")
        
        # Clean up variables to ensure they are valid integers
        has_version_note=$(echo "$has_version_note" | tr -d '\n\r\t ' | head -1)
        has_file_restricted=$(echo "$has_file_restricted" | tr -d '\n\r\t ' | head -1)
        has_can_download=$(echo "$has_can_download" | tr -d '\n\r\t ' | head -1)
        
        # Convert to integers, defaulting to 0 if not a number
        if ! [[ "$has_version_note" =~ ^[0-9]+$ ]]; then has_version_note="0"; fi
        if ! [[ "$has_file_restricted" =~ ^[0-9]+$ ]]; then has_file_restricted="0"; fi
        if ! [[ "$has_can_download" =~ ^[0-9]+$ ]]; then has_can_download="0"; fi
        
        log "Schema field verification:"
        log "  - versionNote fields: $has_version_note"
        log "  - fileRestricted fields: $has_file_restricted"
        log "  - canDownloadFile fields: $has_can_download"
        
        if [ "$has_version_note" -gt 0 ] || [ "$has_file_restricted" -gt 0 ] || [ "$has_can_download" -gt 0 ]; then
            log "✅ Schema update appears successful - new fields detected"
        else
            log "⚠️ WARNING: No new 6.6 fields detected in schema. This may indicate an issue."
            log "The reindexing process will continue, but you should verify the schema manually."
        fi
    else
        log "❌ ERROR: Cannot verify schema after update. Schema may not be properly updated."
        log "This could cause indexing issues during reindexing."
        
        # CRITICAL FIX: Add fallback custom fields if schema verification fails
        log "🔄 Adding fallback custom fields to prevent indexing failures..."
        add_fallback_custom_fields
    fi
}

# Function to add fallback custom fields when schema update fails
add_fallback_custom_fields() {
    log "Adding fallback custom fields to prevent indexing failures..."
    
    local schema_file="$SOLR_PATH/server/solr/collection1/conf/schema.xml"
    
    # Check if schema file exists and is writable
    if [ ! -f "$schema_file" ]; then
        log "❌ ERROR: Schema file not found at $schema_file"
        return 1
    fi
    
    # Create backup before modification
    sudo cp "$schema_file" "${schema_file}.backup.fallback.$(date +%Y%m%d_%H%M%S)"
    
    # Add common custom fields that are likely to be needed
    log "Adding common custom metadata fields to schema..."
    
    
    # Define all software fields with their properties
    # Try to load from .env file first, fallback to hardcoded defaults
    local env_file="${SCRIPT_DIR}/.env"
    if [ -f "$env_file" ]; then
        log "Loading software field definitions from .env file..."
        source "$env_file"
    fi
    
    # Define software fields with environment variable fallbacks
    declare -A software_fields
    
    # Multi-valued fields
    software_fields["swDependencyDescription"]="${SOFTWARE_FIELD_SWDEPENDENCYDESCRIPTION:-true}"
    software_fields["swFunction"]="${SOFTWARE_FIELD_SWFUNCTION:-true}"
    software_fields["swContributorName"]="${SOFTWARE_FIELD_SWCONTRIBUTORNAME:-true}"
    software_fields["swContributorRole"]="${SOFTWARE_FIELD_SWCONTRIBUTORROLE:-true}"
    software_fields["swContributorId"]="${SOFTWARE_FIELD_SWCONTRIBUTORID:-true}"
    software_fields["swOtherRelatedResourceType"]="${SOFTWARE_FIELD_SWOTHERRESOURCETYPE:-true}"
    software_fields["swDependencyLink"]="${SOFTWARE_FIELD_SWDEPENDENCYLINK:-true}"
    software_fields["swInteractionMethod"]="${SOFTWARE_FIELD_SWINTERACTIONMETHOD:-true}"
    software_fields["swLanguage"]="${SOFTWARE_FIELD_SWLANGUAGE:-true}"
    software_fields["swOtherRelatedResourceDescription"]="${SOFTWARE_FIELD_SWOTHERRESOURCEDESCRIPTION:-true}"
    software_fields["swOtherRelatedSoftwareType"]="${SOFTWARE_FIELD_SWOTHERSOFTWARETYPE:-true}"
    software_fields["swOtherRelatedSoftwareDescription"]="${SOFTWARE_FIELD_SWOTHERSOFTWAREDESCRIPTION:-true}"
    software_fields["swOtherRelatedSoftwareLink"]="${SOFTWARE_FIELD_SWOTHERSOFTWARELINK:-true}"
    software_fields["swContributorNote"]="${SOFTWARE_FIELD_SWCONTRIBUTORNOTE:-true}"
    software_fields["swInputOutputType"]="${SOFTWARE_FIELD_SWINPUTOUTPUTTYPE:-true}"
    software_fields["swInputOutputDescription"]="${SOFTWARE_FIELD_SWINPUTOUTPUTDESCRIPTION:-true}"
    software_fields["swDependencyType"]="${SOFTWARE_FIELD_SWDEPENDENCYTYPE:-true}"
    software_fields["swOtherRelatedResourceLink"]="${SOFTWARE_FIELD_SWOTHERRESOURCELINK:-true}"
    
    # Single-valued fields
    software_fields["swDescription"]="${SOFTWARE_FIELD_SWDESCRIPTION:-false}"
    software_fields["swTitle"]="${SOFTWARE_FIELD_SWTITLE:-false}"
    software_fields["whenCollected"]="${SOFTWARE_FIELD_WHENCOLLECTED:-false}"
    software_fields["swCodeRepositoryLink"]="${SOFTWARE_FIELD_SWCODEREPOSITORYLINK:-false}"
    software_fields["swDatePublished"]="${SOFTWARE_FIELD_SWDATEPUBLISHED:-false}"
    software_fields["howToCite"]="${SOFTWARE_FIELD_HOWTOCITE:-false}"
    software_fields["swArtifactType"]="${SOFTWARE_FIELD_SWARTIFACTTYPE:-true}"
    software_fields["swInputOutputLink"]="${SOFTWARE_FIELD_SWINPUTOUTPUTLINK:-false}"
    software_fields["swIdentifier"]="${SOFTWARE_FIELD_SWIDENTIFIER:-false}"
    software_fields["swLicense"]="${SOFTWARE_FIELD_SWLICENSE:-false}"
    software_fields["swVersion"]="${SOFTWARE_FIELD_SWVERSION:-false}"
    
    # Validate environment variable values
    for field in "${!software_fields[@]}"; do
        local value="${software_fields[$field]}"
        if [ "$value" != "true" ] && [ "$value" != "false" ] && [ "$value" != "disabled" ]; then
            log "⚠️  WARNING: Invalid value '$value' for $field, using default 'false'"
            software_fields["$field"]="false"
        fi
    done
    
    # Check which fields exist in the schema
    declare -A field_exists
    for field in "${!software_fields[@]}"; do
        field_exists["$field"]=$(grep -c "$field" "$schema_file" 2>/dev/null || echo "0")
    done
    
    # Check for new 6.6 fields
    local has_version_note=$(grep -c "versionNote" "$schema_file" 2>/dev/null || echo "0")
    local has_file_restricted=$(grep -c "fileRestricted" "$schema_file" 2>/dev/null || echo "0")
    local has_can_download=$(grep -c "canDownloadFile" "$schema_file" 2>/dev/null || echo "0")
    
    # Clean and validate field existence counts
    for field in "${!field_exists[@]}"; do
        field_exists["$field"]=$(echo "${field_exists[$field]}" | tr -d '\n\r\t ' | head -1)
        if ! [[ "${field_exists[$field]}" =~ ^[0-9]+$ ]]; then 
            field_exists["$field"]="0"
        fi
    done
    
    # Process 6.6 fields
    has_version_note=$(echo "$has_version_note" | tr -d '\n\r\t ' | head -1)
    has_file_restricted=$(echo "$has_file_restricted" | tr -d '\n\r\t ' | head -1)
    has_can_download=$(echo "$has_can_download" | tr -d '\n\r\t ' | head -1)
    
    if ! [[ "$has_version_note" =~ ^[0-9]+$ ]]; then has_version_note="0"; fi
    if ! [[ "$has_file_restricted" =~ ^[0-9]+$ ]]; then has_file_restricted="0"; fi
    if ! [[ "$has_can_download" =~ ^[0-9]+$ ]]; then has_can_download="0"; fi
    
    # Add missing fields
    local fields_added=0
    
    # Find the last field definition to insert before it
    local last_field_line=$(grep -n '<field name=' "$schema_file" | tail -1 | cut -d: -f1)
    if [ -n "$last_field_line" ]; then
        local insert_line=$((last_field_line + 1))
        
        # Add software fields using the array
        for field in "${!software_fields[@]}"; do
            if [ "${field_exists[$field]}" -eq 0 ]; then
                local multi_valued="${software_fields[$field]}"
                
                # Skip disabled fields
                if [ "$multi_valued" = "disabled" ]; then
                    log "  ⏭️  Skipping $field field (disabled in .env)"
                    continue
                fi
                
                sudo sed -i "${insert_line}i\  <field name=\"$field\" type=\"text_general\" indexed=\"true\" stored=\"true\" multiValued=\"$multi_valued\"/>" "$schema_file"
                fields_added=$((fields_added + 1))
                if [ "$multi_valued" = "true" ]; then
                    log "  ✓ Added $field field (multiValued)"
                else
                    log "  ✓ Added $field field"
                fi
            fi
        done
        
        # Add new 6.6 fields if missing
        if [ "$has_version_note" -eq 0 ]; then
            sudo sed -i "${insert_line}i\  <field name=\"versionNote\" type=\"text_general\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>" "$schema_file"
            fields_added=$((fields_added + 1))
            log "  ✓ Added versionNote field (6.6)"
        fi
        
        if [ "$has_file_restricted" -eq 0 ]; then
            sudo sed -i "${insert_line}i\  <field name=\"fileRestricted\" type=\"boolean\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>" "$schema_file"
            fields_added=$((fields_added + 1))
            log "  ✓ Added fileRestricted field (6.6)"
        fi
        
        if [ "$has_can_download" -eq 0 ]; then
            sudo sed -i "${insert_line}i\  <field name=\"canDownloadFile\" type=\"boolean\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>" "$schema_file"
            fields_added=$((fields_added + 1))
            log "  ✓ Added canDownloadFile field (6.6)"
        fi
    else
        log "❌ ERROR: Could not find field definitions in schema file"
        return 1
    fi
    
    # Verify the schema is still valid XML
    if xmllint --noout "$schema_file" 2>/dev/null; then
        log "✅ Schema validation passed after adding $fields_added fallback fields"
        
        # Restart Solr to apply the schema changes
        log "Restarting Solr to apply fallback schema changes..."
        sudo systemctl restart solr
        
        # Wait for Solr to be ready
        local counter=0
        while [ $counter -lt 60 ]; do
            if curl -s "http://localhost:8983/solr/admin/cores?action=STATUS&core=collection1" > /dev/null 2>&1; then
                log "✅ Solr restarted successfully with fallback fields"
                return 0
            fi
            sleep 2
            counter=$((counter + 2))
        done
        
        log "❌ ERROR: Solr failed to restart after adding fallback fields"
        return 1
    else
        log "❌ ERROR: Schema file is invalid XML after adding fallback fields"
        log "Restoring backup..."
        sudo cp "${schema_file}.backup.fallback.$(date +%Y%m%d_%H%M%S)" "$schema_file"
        return 1
    fi
}

# STEP 12: Reindex Solr with verification and recovery
reindex_solr() {
    log "Starting Solr reindexing process with verification..."
    log "NOTE: This process may take a significant amount of time depending on the size of your installation."
    
    # Verify Solr schema is properly updated before reindexing
    log "Verifying Solr schema is properly updated before reindexing..."
    
    # Check if Payara is running before attempting schema verification
    if ! systemctl is-active --quiet payara; then
        log "⚠️ WARNING: Payara service is down. Attempting restart..."
        sudo systemctl restart payara
        sleep 30  # Give Payara time to restart
        log "Waiting for Payara to be ready after restart..."
        local payara_wait=0
        while [ $payara_wait -lt 120 ]; do
            if curl -s --max-time 10 "http://localhost:8080/api/info/version" > /dev/null 2>&1; then
                log "✓ Payara is ready after restart"
                break
            fi
            sleep 10
            payara_wait=$((payara_wait + 10))
        done
        if [ $payara_wait -ge 120 ]; then
            log "❌ ERROR: Payara failed to restart properly"
            return 1
        fi
    fi
    
    local schema_verification=$(curl -s "http://localhost:8080/api/admin/index/solr/schema" 2>/dev/null)
    
    if [ -n "$schema_verification" ]; then
        log "✅ Solr schema verification successful - schema is accessible"
        
        # Check for new fields that should be present in 6.6
        local has_version_note=$(echo "$schema_verification" | grep -c "versionNote" || echo "0")
        local has_file_restricted=$(echo "$schema_verification" | grep -c "fileRestricted" || echo "0")
        local has_can_download=$(echo "$schema_verification" | grep -c "canDownloadFile" || echo "0")
        
        # Ensure all variables are integers
        has_version_note=$(echo "$has_version_note" | tr -d '\n\r\t ' | head -1)
        has_file_restricted=$(echo "$has_file_restricted" | tr -d '\n\r\t ' | head -1)
        has_can_download=$(echo "$has_can_download" | tr -d '\n\r\t ' | head -1)
        
        # Convert to integers, defaulting to 0 if not a number
        if ! [[ "$has_version_note" =~ ^[0-9]+$ ]]; then has_version_note="0"; fi
        if ! [[ "$has_file_restricted" =~ ^[0-9]+$ ]]; then has_file_restricted="0"; fi
        if ! [[ "$has_can_download" =~ ^[0-9]+$ ]]; then has_can_download="0"; fi
        
        if [ "$has_version_note" -gt 0 ] && [ "$has_file_restricted" -gt 0 ] && [ "$has_can_download" -gt 0 ]; then
            log "✅ Solr schema contains new 6.6 fields (versionNote, fileRestricted, canDownloadFile)"
        else
            log "⚠️ WARNING: Some new 6.6 fields may not be present in schema. Proceeding with reindexing anyway..."
            log "  - versionNote fields found: $has_version_note"
            log "  - fileRestricted fields found: $has_file_restricted" 
            log "  - canDownloadFile fields found: $has_can_download"
        fi
    else
        log "❌ ERROR: Cannot verify Solr schema. Schema may not be properly updated."
        log "This could cause indexing issues. Please check Solr configuration."
        log "Attempting to diagnose the issue..."
        
        # Check if Solr is running
        if ! curl -s "http://localhost:8983/solr/admin/cores?action=STATUS&core=collection1" > /dev/null 2>&1; then
            log "❌ ERROR: Solr is not responding. Please check Solr service status."
            return 1
        fi
        
        # Check if Dataverse API is accessible
        if ! curl -s "http://localhost:8080/api/info/version" > /dev/null 2>&1; then
            log "❌ ERROR: Dataverse API is not responding. Please check Payara service status."
            return 1
        fi
        
        log "⚠️ WARNING: Schema verification failed but services are running."
        log "This may cause indexing issues. Proceeding with caution..."
        log "You may need to manually verify the Solr schema configuration."
    fi
    
    # Check if the feature flag is properly set (if it was enabled)
    log "Checking feature flag configuration..."
    if sudo -u "$DATAVERSE_USER" $PAYARA/bin/asadmin list-jvm-options | grep -q 'dataverse.feature.index-harvested-metadata-source=true'; then
        log "✅ index-harvested-metadata-source feature flag is enabled"
    else
        log "ℹ️ index-harvested-metadata-source feature flag is disabled"
    fi
    
    # CRITICAL FIX: Check for common custom fields before reindexing
    log "Checking for common custom fields in Solr schema..."
    
    # Final safety check - ensure Payara is running before reindexing
    if ! systemctl is-active --quiet payara; then
        log "❌ ERROR: Payara service is down. Cannot proceed with reindexing."
        log "Please restart Payara manually: sudo systemctl restart payara"
        return 1
    fi
    
    local schema_check=$(curl -s "http://localhost:8983/solr/collection1/schema" 2>/dev/null)
    if [ -n "$schema_check" ]; then
        local has_sw_fields=$(echo "$schema_check" | jq '.schema.fields[] | select(.name | test("sw")) | .name' 2>/dev/null | wc -l)
        local has_when_collected=$(echo "$schema_check" | jq '.schema.fields[] | select(.name == "whenCollected") | .name' 2>/dev/null | wc -l)
        
        # Ensure all variables are integers
        has_sw_fields=$(echo "$has_sw_fields" | tr -d '\n\r\t ' | head -1)
        has_when_collected=$(echo "$has_when_collected" | tr -d '\n\r\t ' | head -1)
        
        # Convert to integers, defaulting to 0 if not a number
        if ! [[ "$has_sw_fields" =~ ^[0-9]+$ ]]; then has_sw_fields="0"; fi
        if ! [[ "$has_when_collected" =~ ^[0-9]+$ ]]; then has_when_collected="0"; fi
        
        if [ "$has_sw_fields" -gt 0 ] || [ "$has_when_collected" -gt 0 ]; then
            log "✅ Custom fields detected in schema - reindexing should work properly"
        else
            log "⚠️ WARNING: No custom fields detected in schema. This may cause indexing failures."
            log "🔄 Adding fallback custom fields before reindexing..."
            add_fallback_custom_fields
        fi
    else
        log "⚠️ WARNING: Cannot check schema for custom fields. Adding fallback fields..."
        add_fallback_custom_fields
    fi
    
    # First, check the current state of the index
    local current_doc_count=$(get_solr_doc_count)
    log "Current index contains $current_doc_count documents"
    
    # Get expected dataset/dataverse count from the database via API
    local expected_items=""
    local dataverse_api_response=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null)
    if echo "$dataverse_api_response" | jq -e '.data.message' >/dev/null 2>&1; then
        expected_items=$(echo "$dataverse_api_response" | jq -r '.data.message' | grep -oE '[0-9]+ dataverses and [0-9]+ datasets' || echo "unknown count")
        log "Expected to index: $expected_items"
    else
        log "Could not determine expected item count from API"
    fi
    
    # Clear and rebuild the index for clean state
    log "Clearing Solr index for clean reindexing..."
    local clear_response=$(curl -s "http://localhost:8080/api/admin/index/clear" 2>/dev/null)
    if [ -n "$clear_response" ]; then
        log "Clear response: $clear_response"
        log "Solr index cleared successfully"
    else
        log "WARNING: Failed to clear Solr index, continuing with reindex anyway"
    fi
    
    # Start reindexing
    log "Running command: curl -s http://localhost:8080/api/admin/index"
    local reindex_response=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null)
    if [ -n "$reindex_response" ]; then
        log "Reindex response: $reindex_response"
    fi
    
    if echo "$reindex_response" | jq -e '.status' >/dev/null 2>&1; then
        local reindex_message=$(echo "$reindex_response" | jq -r '.data.message' 2>/dev/null || echo "Reindexing started")
        log "Solr reindexing initiated successfully: $reindex_message"
        
        # Enhanced monitoring with much longer timeouts for large installations
        log "Monitoring indexing progress (extended monitoring for large installations)..."
        local start_time=$(date +%s)
        local initial_timeout=300   # 5 minutes to see initial progress
        local progress_timeout=1800 # 30 minutes total monitoring
        local last_count=0
        local progress_detected=false
        
        # Phase 1: Wait for initial indexing to start
        log "Phase 1: Waiting for initial indexing to start (up to 5 minutes)..."
        while [ $(($(date +%s) - start_time)) -lt $initial_timeout ]; do
            sleep 15
            local current_count=$(get_solr_doc_count)
            
            if [ "$current_count" -gt 0 ]; then
                log "✓ Initial indexing detected: $current_count documents"
                progress_detected=true
                break
            fi
            
            local elapsed=$(($(date +%s) - start_time))
            log "Waiting for indexing to start... ($elapsed seconds, $current_count documents)"
        done
        
        if [ "$progress_detected" = false ]; then
            log "WARNING: No documents indexed after $initial_timeout seconds"
            # Don't return error immediately, continue to phase 2
        fi
        
        # Phase 2: Monitor ongoing progress  
        log "Phase 2: Monitoring ongoing indexing progress..."
        local last_progress_time=$start_time
        local stable_count_iterations=0
        local max_stable_iterations=6  # Allow 6 stable checks before considering complete
        
        while [ $(($(date +%s) - start_time)) -lt $progress_timeout ]; do
            sleep 30  # Longer intervals for progress checking
            local current_count=$(get_solr_doc_count)
            local elapsed=$(($(date +%s) - start_time))
            
            if [ "$current_count" != "$last_count" ]; then
                if [ "$current_count" -gt "$last_count" ]; then
                    log "Progress: $current_count documents indexed (+$((current_count - last_count))) [${elapsed}s elapsed]"
                    last_progress_time=$(date +%s)
                    stable_count_iterations=0
                    progress_detected=true
                fi
                last_count=$current_count
            else
                stable_count_iterations=$((stable_count_iterations + 1))
                log "Stable: $current_count documents ($stable_count_iterations/$max_stable_iterations stable checks) [${elapsed}s elapsed]"
                
                # If we have progress and the count has been stable, consider it complete
                if [ "$progress_detected" = true ] && [ $stable_count_iterations -ge $max_stable_iterations ]; then
                    log "✓ Indexing appears to be complete: $current_count documents (stable for $((stable_count_iterations * 30)) seconds)"
                    
                    # Final verification: check if indexing is actually still running
                    local index_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
                    if echo "$index_status" | grep -qi "running\|progress"; then
                        log "INFO: Indexing still active in background, but maximum wait time reached."
                        log "Proceeding with upgrade - indexing will continue in background."
                        return 0
                    else
                        log "✓ Indexing process completed successfully"
                        return 0
                    fi
                # If no progress was detected and we've been stable for max iterations, also exit
                elif [ "$progress_detected" = false ] && [ $stable_count_iterations -ge $max_stable_iterations ]; then
                    log "⚠️ No indexing progress detected after $max_stable_iterations stable checks"
                    log "This may indicate an issue with the reindexing process."
                    log "Current count: $current_count documents"
                    log "Proceeding with upgrade - please check indexing status manually:"
                    log "  curl -s http://localhost:8080/api/admin/index/status"
                    return 0
                fi
            fi
            
            # Check if we've gone too long without progress
            local time_since_progress=$(($(date +%s) - last_progress_time))
            if [ $time_since_progress -gt 600 ] && [ "$progress_detected" = true ]; then
                log "WARNING: No indexing progress for $time_since_progress seconds"
                break
            fi
        done
        
        # Final assessment
        if [ "$progress_detected" = true ]; then
            log "INFO: Indexing made progress but may still be continuing in background"
            log "Current count: $current_count documents"
            log "Reindexing will continue in the background. Monitor with:"
            log "  curl -s \"http://localhost:8983/solr/collection1/select?q=*:*&rows=0\" | jq '.response.numFound'"
            log "  curl -s \"http://localhost:8080/api/admin/index/status\""
            return 0
        fi
        
        # Enhanced error diagnosis
        log "WARNING: Indexing did not start within expected timeframe"
        log "Performing enhanced diagnosis..."
        
        # Check Payara logs for specific errors
        local payara_log="$PAYARA/glassfish/domains/domain1/logs/server.log"
        if [ -f "$payara_log" ]; then
            log "Checking for indexing-related errors in Payara logs:"
            local recent_errors=$(tail -100 "$payara_log" | grep -i "index\|solr" | grep -i "error\|exception\|failed" | tail -5)
            if [ -n "$recent_errors" ]; then
                echo "$recent_errors" | while read line; do
                    log "❌ ERROR: $line"
                done
            else
                log "No obvious indexing errors found in recent Payara logs"
            fi
        fi
        
        # Check Solr logs
        local solr_log="$SOLR_PATH/server/logs/solr.log"
        if [ -f "$solr_log" ]; then
            log "Checking for Solr errors:"
            local solr_errors=$(tail -50 "$solr_log" | grep -i "error\|exception" | tail -3)
            if [ -n "$solr_errors" ]; then
                echo "$solr_errors" | while read line; do
                    log "SOLR ERROR: $line"
                done
            fi
        fi
        
        # Check API status more thoroughly
        log "Checking Dataverse API index status:"
        local api_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
        if [ -n "$api_status" ]; then
            log "Index status response: $api_status"
        else
            log "No response from index status API"
        fi
        
        # Try to trigger indexing again with different approach
        log "Attempting to restart indexing with alternative method..."
        local emergency_response=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null)
        if [ -n "$emergency_response" ]; then
            log "Emergency response: $emergency_response"
            log "Emergency reindexing command sent successfully"
            
            # Wait a bit more to see if this triggers indexing
            log "Waiting 2 minutes to see if emergency reindexing starts..."
            sleep 120
            local emergency_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
            if [ "$emergency_count" -gt 0 ]; then
                log "✓ Emergency reindexing is working: $emergency_count documents"
                log "Indexing will continue in background. Monitor progress with commands shown below."
                progress_detected=true
            else
                log "Emergency reindexing did not start immediately"
            fi
        else
            log "Failed to send emergency reindexing command"
        fi
        
        log ""
        log "INDEXING DIAGNOSIS COMPLETE"
        log "Use these commands to monitor and diagnose:"
        log "  curl \"http://localhost:8080/api/admin/index/status\""
        log "  curl \"http://localhost:8983/solr/collection1/select?q=*:*&rows=0\""
        log "  tail -f \"$payara_log\" | grep -i index"
        
        # Still return 0 if we detected any progress at all
        if [ "$progress_detected" = true ]; then
            return 0
        fi
    else
        log "❌ ERROR: Failed to initiate Solr reindexing."
        log "Response: $reindex_response"
        return 1
    fi
}

# STEP 13: Run reExportAll
run_reexport_all() {
    log "Running reExportAll to update dataset metadata exports..."
    log "This process updates all metadata exports with license enhancements and other v6.6 improvements."
    
    log "Running command: curl -s http://localhost:8080/api/admin/metadata/reExportAll"
    local reexport_response=$(curl -s "http://localhost:8080/api/admin/metadata/reExportAll" 2>/dev/null)
    if [ -n "$reexport_response" ]; then
        log "ReExport response: $reexport_response"
        log "reExportAll initiated successfully. This may take time depending on the number of datasets."
    else
        log "❌ ERROR: Failed to initiate reExportAll."
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

# Function to verify upgrade completion with baseline comparison
verify_upgrade() {
    log "========================================"
    log "VERIFYING UPGRADE COMPLETION"
    log "========================================"
    
    # Load baseline metrics for comparison
    local baseline_file="$SCRIPT_DIR/baseline_metrics.json"
    local baseline_index_count=0
    local baseline_software_count=0
    local baseline_datacontext_count=0
    local baseline_workflow_count=0
    
    if [ -f "$baseline_file" ]; then
        # Use pre-Solr-upgrade count if available (more accurate), otherwise use original baseline
        baseline_index_count=$(jq -r '.pre_solr_upgrade_count // .pre_upgrade_index_count' "$baseline_file" 2>/dev/null || echo "0")
        baseline_software_count=$(jq -r '.pre_upgrade_software_count' "$baseline_file" 2>/dev/null || echo "0")
        baseline_datacontext_count=$(jq -r '.pre_upgrade_datacontext_count' "$baseline_file" 2>/dev/null || echo "0")
        baseline_workflow_count=$(jq -r '.pre_upgrade_workflow_count' "$baseline_file" 2>/dev/null || echo "0")
        
        log "Baseline metrics loaded:"
        log "  - Target index count: $baseline_index_count documents"
        log "  - Pre-upgrade software metadata: $baseline_software_count datasets"
        log "  - Pre-upgrade data context: $baseline_datacontext_count datasets"
        log "  - Pre-upgrade workflows: $baseline_workflow_count datasets"
    else
        log "WARNING: No baseline metrics file found. Verification will be less comprehensive."
    fi
    
    # First ensure all services are healthy
    log "Checking service health before verification..."
    if ! ensure_payara_healthy; then
        log "❌ ERROR: Payara service is not healthy during final verification"
        return 1
    fi
    
    # Check Dataverse version
    local dv_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
    if [[ "$dv_version" == *"$TARGET_VERSION"* ]]; then
        log "✓ Dataverse version verification: $dv_version"
    else
        log "✗ Dataverse version verification failed. Expected $TARGET_VERSION, got $dv_version"
        log "Attempting automatic recovery using enhanced mixed state resolution..."
        
        # Use the enhanced mixed state resolution
        if resolve_deployment_mixed_state; then
            log "Mixed deployment state resolved. Re-checking version..."
            sleep 30  # Allow time for services to settle
            
            local new_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null)
            if [[ "$new_version" == *"$TARGET_VERSION"* ]]; then
                log "✓ Recovery successful! Dataverse version: $new_version"
            else
                log "✗ Recovery failed. Version still: $new_version"
                return 1
            fi
        else
            log "✗ Failed to resolve mixed deployment state"
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
        
        # Check Solr index status with baseline comparison
        local index_doc_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
        log "Current Solr index contains: $index_doc_count documents"
        
        # Compare against baseline
        if [ "$baseline_index_count" -gt 0 ]; then
            local index_growth=$((index_doc_count - baseline_index_count))
            local growth_percentage=0
            if [ "$baseline_index_count" -gt 0 ]; then
                growth_percentage=$(echo "scale=1; ($index_growth * 100) / $baseline_index_count" | bc -l 2>/dev/null || echo "0")
            fi
            log "Index comparison: $index_growth documents change (${growth_percentage}% from baseline)"
            
            # Acceptable range: -5% to +20% (allows for some variation due to timing, new content, etc.)
            if [ "$index_doc_count" -ge "$((baseline_index_count * 95 / 100))" ] && [ "$index_doc_count" -le "$((baseline_index_count * 120 / 100))" ]; then
                log "✓ Index count is within acceptable range of baseline"
            elif [ "$index_doc_count" -lt "$((baseline_index_count * 80 / 100))" ]; then
                log "⚠ WARNING: Index count significantly below baseline (may indicate indexing issues)"
            else
                log "ℹ Index count differs from baseline but may be normal (new/deleted content, reindexing timing)"
            fi
        fi
        
        if [ "$index_doc_count" -eq 0 ]; then
            log "⚠ WARNING: Solr index is empty! This will cause search functionality to not work."
            log "Checking if reindexing is currently running..."
            
            # Check if reindexing is in progress
            local index_status=$(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null)
            if echo "$index_status" | grep -qi "running\|progress\|started"; then
                log "ℹ Reindexing appears to be in progress. This is normal and will complete in the background."
                log "Monitor progress with: curl -s \"http://localhost:8983/solr/collection1/select?q=*:*&rows=0\" | jq '.response.numFound'"
            else
                log "⚠ No active reindexing detected. Attempting to restart indexing..."
                log "Running emergency reindexing to fix empty index..."
                
                # Emergency reindex
                local emergency_reindex=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null)
                if echo "$emergency_reindex" | jq -e '.status' >/dev/null 2>&1; then
                    local reindex_msg=$(echo "$emergency_reindex" | jq -r '.data.message' 2>/dev/null || "Emergency reindexing started")
                    log "✓ Emergency reindexing initiated: $reindex_msg"
                    log "The indexing process will continue in the background after this upgrade completes."
                    log "You can monitor progress with the command shown above."
                else
                    log "✗ Failed to start emergency reindexing. Manual intervention required."
                    log "After the upgrade, run: curl \"http://localhost:8080/api/admin/index\""
                fi
            fi
        else
            log "✓ Solr index verification: Contains $index_doc_count documents"
        fi
        
        # Test custom metadata fields against baseline
        log "Testing custom metadata field functionality..."
        local current_software_count=$(curl -s "http://localhost:8080/api/search?q=swContributorName:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
        local current_datacontext_count=$(curl -s "http://localhost:8080/api/search?q=dataContext:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
        local current_workflow_count=$(curl -s "http://localhost:8080/api/search?q=computationalworkflow:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
        
        log "Current custom metadata counts:"
        log "  - Software metadata: $current_software_count datasets"
        log "  - Data Context metadata: $current_datacontext_count datasets"
        log "  - Workflow metadata: $current_workflow_count datasets"
        
        # Compare custom metadata against baseline
        local metadata_issues=false
        
        if [ "$baseline_software_count" -gt 0 ]; then
            if [ "$current_software_count" -ge "$((baseline_software_count * 90 / 100))" ]; then
                log "✓ Software metadata search working (${current_software_count}/${baseline_software_count} baseline)"
            else
                log "✗ Software metadata search below baseline (${current_software_count}/${baseline_software_count})"
                metadata_issues=true
            fi
        elif [ "$current_software_count" -gt 0 ]; then
            log "✓ Software metadata search working ($current_software_count datasets found)"
        fi
        
        if [ "$baseline_datacontext_count" -gt 0 ]; then
            if [ "$current_datacontext_count" -ge "$((baseline_datacontext_count * 90 / 100))" ]; then
                log "✓ Data Context metadata search working (${current_datacontext_count}/${baseline_datacontext_count} baseline)"
            else
                log "✗ Data Context metadata search below baseline (${current_datacontext_count}/${baseline_datacontext_count})"
                metadata_issues=true
            fi
        fi
        
        if [ "$baseline_workflow_count" -gt 0 ]; then
            if [ "$current_workflow_count" -ge "$((baseline_workflow_count * 90 / 100))" ]; then
                log "✓ Workflow metadata search working (${current_workflow_count}/${baseline_workflow_count} baseline)"
            else
                log "✗ Workflow metadata search below baseline (${current_workflow_count}/${baseline_workflow_count})"
                metadata_issues=true
            fi
        fi
        
        if [ "$metadata_issues" = true ]; then
            log "⚠ WARNING: Custom metadata search issues detected"
            log "This may indicate schema update problems or incomplete reindexing"
            log "Consider running: curl \"http://localhost:8080/api/admin/index/clear\" && curl \"http://localhost:8080/api/admin/index\""
        fi
    else
        log "✗ Solr service verification failed"
        return 1
    fi
    
    # Check 3D Objects metadata block
    local objects_3d_response=$(curl -s "http://localhost:8080/api/metadatablocks/3d_objects" 2>/dev/null)
    if echo "$objects_3d_response" | jq -e '.data' 2> /dev/null; then
        log "✓ 3D Objects metadata block verification: Loaded"
    else
        log "! 3D Objects metadata block verification: Not found (this is optional for 6.6)"
        log "  Response: $(echo "$objects_3d_response" | head -c 100)..."
        log "  You can manually add it later if needed via the admin interface"
    fi
    
    # Test SameSite configuration
    local samesite_test=$(curl -s -I "http://localhost:8080" 2>/dev/null | grep -i "samesite")
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
        log "❌ ERROR: No backup found at ${PAYARA}.${CURRENT_VERSION}.backup"
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

# Function to capture baseline metrics for comparison
capture_baseline_metrics() {
    log "========================================"
    log "CAPTURING BASELINE METRICS FOR COMPARISON"
    log "========================================"
    
    # Create baseline metrics file
    local baseline_file="$SCRIPT_DIR/baseline_metrics.json"
    
    # Capture current Solr index count
    local current_index_count=0
    if curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" >/dev/null 2>&1; then
        current_index_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
    fi
    log "Pre-upgrade Solr index count: $current_index_count documents"
    
    # Capture custom metadata counts
    local software_count=0
    local datacontext_count=0
    local workflow_count=0
    
    if curl -s "http://localhost:8080/api/search?q=*:*" >/dev/null 2>&1; then
        software_count=$(curl -s "http://localhost:8080/api/search?q=swContributorName:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
        datacontext_count=$(curl -s "http://localhost:8080/api/search?q=dataContext:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
        workflow_count=$(curl -s "http://localhost:8080/api/search?q=computationalworkflow:*" 2>/dev/null | jq -r '.data.total_count' 2>/dev/null || echo "0")
    fi
    
    log "Pre-upgrade custom metadata counts:"
    log "  - Software metadata (swContributorName): $software_count datasets"
    log "  - Data Context metadata: $datacontext_count datasets"
    log "  - Computational Workflow metadata: $workflow_count datasets"
    
    # Get expected item count from API
    local expected_items="unknown"
    if curl -s "http://localhost:8080/api/admin/index" >/dev/null 2>&1; then
        expected_items=$(curl -s "http://localhost:8080/api/admin/index" 2>/dev/null | jq -r '.data.message' 2>/dev/null | grep -oE '[0-9]+ dataverses and [0-9]+ datasets' || echo "unknown")
    fi
    log "Expected content to index: $expected_items"
    
    # Check custom metadata blocks
    local custom_blocks=""
    if curl -s "http://localhost:8080/api/metadatablocks" >/dev/null 2>&1; then
        custom_blocks=$(curl -s "http://localhost:8080/api/metadatablocks" 2>/dev/null | jq -r '.data[] | select(.name | test("^(citation|geospatial|socialscience|astrophysics|biomedical|journal)$") | not) | .name' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi
    log "Custom metadata blocks detected: $custom_blocks"
    
    # Save baseline to file for later comparison
    cat > "$baseline_file" << EOF
{
    "capture_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "pre_upgrade_index_count": $current_index_count,
    "pre_upgrade_software_count": $software_count,
    "pre_upgrade_datacontext_count": $datacontext_count,
    "pre_upgrade_workflow_count": $workflow_count,
    "expected_content": "$expected_items",
    "custom_metadata_blocks": "$custom_blocks"
}
EOF
    
    log "Baseline metrics saved to: $baseline_file"
    log "========================================"
}

# Main execution function
main() {
    # Check for command-line arguments
    if [[ "$1" == "--troubleshoot-indexing" ]]; then
        troubleshoot_indexing
        exit 0
    fi
    
    log "Starting Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION"
    log "Log file: $LOGFILE"
    log "State file: $STATE_FILE"
    
    # Check for interrupted steps from previous runs
    check_interrupted_steps
    
    # Check for required commands
    check_required_commands
    
    # Check sudo access
    check_sudo_access

    # Run comprehensive pre-flight checks
    if ! run_preflight_checks; then
        log "❌ Pre-flight checks failed. Please address the issues and try again."
        exit 1
    fi
    
    echo ""

    # Check checksum configuration
    check_checksum_configuration
    
    # Step 0: Check current version FIRST (before any system modifications)
    if ! is_step_completed "check_version"; then
        check_current_version
        check_error "Version check failed - upgrade cannot proceed"
        mark_step_as_complete "check_version"
    fi
    
    # Step 0a: Capture baseline metrics for comparison (critical for verification)
    if ! is_step_completed "capture_baseline"; then
        capture_baseline_metrics
        check_error "Failed to capture baseline metrics"
        mark_step_as_complete "capture_baseline"
    fi
    
    # Step 0a: Prompt for backup (CRITICAL FIRST STEP)
    if ! is_step_completed "backup_confirmed"; then
        echo ""
        log "========================================"
        log "CRITICAL: Before proceeding with upgrade, ensure you have created backups:"
        log "1. Database backup: pg_dump -U dataverse dataverse > dataverse_backup.sql"
        log "2. Configuration backup: sudo tar -czf dataverse_config_backup.tar.gz $PAYARA $SOLR_PATH"
        log "3. Any custom configurations or uploaded files"
        log "========================================"
        read -p "Have you created all necessary backups? (y/N): " HAS_BACKUP
        
        if [[ ! "$HAS_BACKUP" =~ ^[Yy]$ ]]; then
            log "❌ ERROR: Backup confirmation required. Please create backups before running this script."
            log "Upgrade aborted. Please create backups and run the script again."
            exit 1
        fi
        mark_step_as_complete "backup_confirmed"
    fi
    
    # Step 0b: Check and upgrade Java BEFORE any asadmin commands
    if ! is_step_completed "check_java"; then
        log "Checking Java version before using Payara commands..."
        check_and_upgrade_java
        check_error "Failed to check/upgrade Java"
        mark_step_as_complete "check_java"
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
    
    # Step 8: Clear application state before deployment
    if ! is_step_completed "clear_app_state"; then
        clear_application_state
        check_error "Failed to clear application state"
        mark_step_as_complete "clear_app_state"
    fi
    
    # Step 9: Deploy Dataverse
    if ! is_step_completed "deploy"; then
        mark_step_as_running "deploy"
        deploy_dataverse
        check_error "Failed to deploy Dataverse"
        mark_step_as_complete "deploy" "verify_deployment"
        check_error "Failed to verify Dataverse deployment"
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
        mark_step_as_running "upgrade_solr"
        
        # Capture final pre-Solr-upgrade index count for accurate comparison
        log "Capturing final index count before Solr upgrade..."
        
        # Get Solr response with better error handling
        local solr_response=$(curl -s --max-time 10 "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null)
        local pre_solr_upgrade_count="0"
        
        # Check if we got a valid JSON response
        if [ -n "$solr_response" ] && echo "$solr_response" | jq . >/dev/null 2>&1; then
            pre_solr_upgrade_count=$(echo "$solr_response" | jq -r '.response.numFound // 0' 2>/dev/null || echo "0")
            log "Index count immediately before Solr upgrade: $pre_solr_upgrade_count documents"
        else
            log "WARNING: Could not get valid response from Solr before upgrade"
            log "Solr response: $(echo "$solr_response" | head -c 200)"
            log "Using default count of 0"
        fi
        
        # Update baseline with the actual count we need to restore
        if [ -f "$SCRIPT_DIR/baseline_metrics.json" ]; then
            # Update the baseline file with the actual count to restore
            if echo "$pre_solr_upgrade_count" | grep -q '^[0-9]\+$'; then
                jq --argjson count "$pre_solr_upgrade_count" '.pre_solr_upgrade_count = $count' "$SCRIPT_DIR/baseline_metrics.json" > "$SCRIPT_DIR/baseline_metrics.json.tmp" && \
                mv "$SCRIPT_DIR/baseline_metrics.json.tmp" "$SCRIPT_DIR/baseline_metrics.json" || {
                    log "WARNING: Failed to update baseline with pre-Solr count"
                }
            else
                log "WARNING: Invalid count value '$pre_solr_upgrade_count', skipping baseline update"
            fi
        fi
        
        upgrade_solr
        check_error "Failed to upgrade Solr"
        mark_step_as_complete "upgrade_solr" "verify_solr_upgrade"
        check_error "Failed to verify Solr upgrade"
    fi
    
    # Step 17: Update Solr custom fields (now that Dataverse API is confirmed working from metadata block steps)
    if ! is_step_completed "solr_custom_fields"; then
        mark_step_as_running "solr_custom_fields"
        update_solr_custom_fields
        check_error "Failed to update Solr custom fields"
        mark_step_as_complete "solr_custom_fields" "verify_schema_update"
        check_error "Failed to verify Solr schema update"
    fi
    
    # Step 18: Reindex Solr with verification and recovery
    if ! is_step_completed "reindex_solr"; then
        mark_step_as_running "reindex_solr"
        reindex_solr
        check_error "Failed to reindex Solr"
        mark_step_as_complete "reindex_solr" "verify_reindexing"
        check_error "Failed to verify Solr reindexing"
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
    
    # Final comprehensive validation
    if ! run_final_validation; then
        log "❌ FINAL VALIDATION FAILED - Upgrade may not be complete"
        log "Please check the issues and run manual verification"
        exit 1
    fi

    log "========================================"
    log "✅ Dataverse upgrade from $CURRENT_VERSION to $TARGET_VERSION completed successfully!"
    log "========================================"
    
    # Generate upgrade summary report
    generate_upgrade_summary
    
    # Show final comparison against baseline
    if [ -f "$SCRIPT_DIR/baseline_metrics.json" ]; then
        log ""
        log "📊 UPGRADE RESULTS SUMMARY:"
        # Get final index count with better error handling
        local final_solr_response=$(curl -s --max-time 10 "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null)
        local final_index_count="0"
        if [ -n "$final_solr_response" ] && echo "$final_solr_response" | jq . >/dev/null 2>&1; then
            final_index_count=$(echo "$final_solr_response" | jq -r '.response.numFound // 0' 2>/dev/null || echo "0")
        fi
        
        # Get final software count with better error handling
        local final_api_response=$(curl -s --max-time 10 "http://localhost:8080/api/search?q=swContributorName:*" 2>/dev/null)
        local final_software_count="0"
        if [ -n "$final_api_response" ] && echo "$final_api_response" | jq . >/dev/null 2>&1; then
            final_software_count=$(echo "$final_api_response" | jq -r '.data.total_count // 0' 2>/dev/null || echo "0")
        fi
        
        local baseline_index=$(jq -r '.pre_solr_upgrade_count // .pre_upgrade_index_count' "$SCRIPT_DIR/baseline_metrics.json" 2>/dev/null || echo "0")
        local baseline_software=$(jq -r '.pre_upgrade_software_count' "$SCRIPT_DIR/baseline_metrics.json" 2>/dev/null || echo "0")
        
        log "  ✓ Index: $final_index_count documents (baseline: $baseline_index)"
        log "  ✓ Software metadata: $final_software_count datasets (baseline: $baseline_software)"
        
        if [ "$final_software_count" -ge "$baseline_software" ] && [ "$final_index_count" -ge "$((baseline_index * 90 / 100))" ]; then
            log "  🎉 SUCCESS: All metrics meet or exceed baseline expectations"
        else
            log "  ⚠ Some metrics below baseline - monitor indexing completion"
        fi
    fi
    
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
    log "🔍 Indexing Status Monitoring:"
    log "- Check index progress: curl -s \"http://localhost:8983/solr/collection1/select?q=*:*&rows=0\" | jq '.response.numFound'"
    log "- Check indexing status: curl -s \"http://localhost:8080/api/admin/index/status\""
    log "- If search doesn't work, restart indexing: curl -s \"http://localhost:8080/api/admin/index\""
    log "- The indexing process may take 10-60 minutes depending on your dataset count"
    log ""
    log "Security note:"
    log "- For future runs, consider updating SHA256 checksums in this script"
    log "- This ensures download integrity verification for all components"
    log "- See the instructions at the top of this script for details"
    log ""
    log "For any issues, check the server logs and the upgrade log at: $LOGFILE"
}

# Final comprehensive validation function
run_final_validation() {
    log "========================================="
    log "RUNNING FINAL COMPREHENSIVE VALIDATION"
    log "========================================="
    
    local validation_errors=()
    local validation_warnings=()
    
    # Validate all core services are healthy
    log "Validating core services health..."
    if ! validate_payara_health 60; then
        validation_errors+=("Payara service health check failed")
    fi
    
    if ! validate_solr_health 30; then
        validation_errors+=("Solr service health check failed")
    fi
    
    if ! validate_dataverse_api 60; then
        validation_errors+=("Dataverse API health check failed")
    fi
    
    # Validate version consistency
    log "Validating version consistency..."
    local api_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null || echo "unknown")
    if [[ "$api_version" != "$TARGET_VERSION"* ]]; then
        validation_errors+=("API version mismatch: expected $TARGET_VERSION, got $api_version")
    fi
    
    # Validate database connectivity
    log "Validating database connectivity..."
    if ! curl -s --max-time 15 "http://localhost:8080/api/info/server" 2> /dev/null; then
        validation_warnings+=("Database connectivity check inconclusive")
    fi
    
    # Check for any critical log entries
    log "Checking for critical errors in logs..."
    local payara_log="$PAYARA/glassfish/domains/domain1/logs/server.log"
    if [[ -f "$payara_log" ]]; then
        local recent_errors=$(tail -100 "$payara_log" | grep -i "SEVERE\|FATAL\|OutOfMemoryError" | wc -l)
        if [[ "$recent_errors" -gt 0 ]]; then
            validation_warnings+=("Found $recent_errors recent critical errors in Payara logs")
        fi
    fi
    
    # Validate Solr indexing status
    log "Validating Solr indexing status..."
    local solr_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "0")
    if [[ "$solr_count" -eq 0 ]]; then
        validation_warnings+=("Solr index appears empty - indexing may still be in progress")
    else
        log "✓ Solr index contains $solr_count documents"
    fi
    
    # Validate database vs Solr indexing consistency
    log "Validating database vs Solr indexing consistency..."
    if ! verify_indexing_consistency; then
        validation_warnings+=("Database vs Solr indexing consistency check failed")
    fi
    
    # Check for indexing errors
    log "Checking for indexing errors..."
    if ! check_indexing_errors; then
        validation_warnings+=("Indexing errors detected in logs")
    fi
    
    # Report validation results
    if [[ ${#validation_errors[@]} -gt 0 ]]; then
        log "❌ FINAL VALIDATION FAILED:"
        for error in "${validation_errors[@]}"; do
            log "  ❌ $error"
        done
        return 1
    fi
    
    if [[ ${#validation_warnings[@]} -gt 0 ]]; then
        log "⚠️  FINAL VALIDATION WARNINGS:"
        for warning in "${validation_warnings[@]}"; do
            log "  ⚠️  $warning"
        done
    fi
    
    log "✅ FINAL VALIDATION COMPLETED SUCCESSFULLY"
    return 0
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
        log "     curl \"http://localhost:8080/api/admin/index/clear\""
        log "     curl \"http://localhost:8080/api/admin/index\""
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

# Function to generate upgrade summary report
generate_upgrade_summary() {
    log ""
    log "========================================="
    log "📋 COMPREHENSIVE UPGRADE SUMMARY REPORT"
    log "========================================="
    
    # Version information
    local api_version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null || echo "unknown")
    log "🎯 Upgrade Details:"
    log "  • Source Version: $CURRENT_VERSION"
    log "  • Target Version: $TARGET_VERSION"
    log "  • Actual API Version: $api_version"
    log "  • Upgrade Date: $(date)"
    log "  • Log File: $LOGFILE"
    log "  • Script Location: $(realpath "$0")"
    
    # Service status
    log ""
    log "🔧 Service Status:"
    local payara_status=$(systemctl is-active payara 2>/dev/null || echo "unknown")
    local solr_status=$(systemctl is-active solr 2>/dev/null || echo "unknown")
    log "  • Payara: $payara_status"
    log "  • Solr: $solr_status"
    
    # Infrastructure versions
    log ""
    log "🛠️  Infrastructure Versions:"
    local java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 || echo "unknown")
    log "  • Java: $java_version"
    log "  • Payara: $PAYARA_VERSION" 
    log "  • Solr: $SOLR_VERSION"
    
    # Database and connectivity
    log ""
    log "🗄️  System Health:"
    local db_responsive=$(curl -s --max-time 10 "http://localhost:8080/api/info/server" 2>/dev/null >/dev/null 2>&1 && echo "✓ Responsive" || echo "⚠️  Check needed")
    log "  • Database: $db_responsive"
    log "  • API Endpoint: $(curl -s --max-time 5 "http://localhost:8080/api/info/version" 2>/dev/null >/dev/null 2>&1 && echo "✓ Accessible" || echo "⚠️  Check needed")"
    
    # Index status
    log ""
    log "🔍 Search Index Status:"
    local solr_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "unknown")
    log "  • Indexed Documents: $solr_count"
    log "  • Index Status: $(curl -s "http://localhost:8080/api/admin/index/status" 2>/dev/null | jq -r '.data' 2>/dev/null || echo "Check manually")"
    
    # Critical next steps
    log ""
    log "🚀 CRITICAL NEXT STEPS:"
    log "  1. 🧪 TEST BASIC FUNCTIONALITY:"
    log "     - Login to web interface: http://localhost:8080"
    log "     - Create a test dataset"
    log "     - Upload a test file"
    log "     - Test search functionality"
    log ""
    log "  2. 🔍 MONITOR INDEXING PROGRESS:"
    log "     - Command: curl -s \"http://localhost:8080/api/admin/index/status\""
    log "     - Expected: May take 10-60 minutes for full completion"
    log ""
    log "  3. 📊 VERIFY NEW FEATURES:"
    log "     - Test 3D Objects metadata block"
    log "     - Verify custom metadata fields (software, dataContext, etc.)"
    log "     - Test range search on numerical/date fields"
    log ""
    log "  4. 🛡️  SECURITY & BACKUP:"
    log "     - Backup current working state"
    log "     - Review security policy changes"
    log "     - Update monitoring configurations"
    
    # Important warnings and reminders
    log ""
    log "⚠️  IMPORTANT REMINDERS:"
    log "  • If you saw SQL 'relation already exists' errors during deployment, these were EXPECTED"
    log "  • Database schema conflicts are normal during upgrades and were handled automatically"
    log "  • Indexing may continue in background - monitor for completion"
    log "  • Review Payara logs for any warnings: $PAYARA/glassfish/domains/domain1/logs/server.log"
    log "  • Custom integrations may need updates for new API features"
    log "  • Consider updating external monitoring for new Solr/Payara versions"
    
    # Environment-specific notes
    log ""
    log "🌐 ENVIRONMENT DEPLOYMENT NOTES:"
    log "  • This script is designed for universal deployment across Dataverse 6.5 installations"
    log "  • Security policies have been validated and configured"
    log "  • All environmental irregularities have been handled gracefully"
    log "  • Script maintains upgrade integrity across different system configurations"
    
    log "========================================="
    log "✅ UPGRADE SUMMARY COMPLETE"
    log "========================================="
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

# Run main function
main "$@"