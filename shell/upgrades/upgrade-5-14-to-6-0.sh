#!/bin/bash

# Dataverse Upgrade Script: 5.14 to 6.0
# This script automates the upgrade process for Dataverse from version 5.14 to 6.0
# It handles the upgrade of Payara, Java, Solr, and all necessary configurations

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

# Function to check available disk space
check_disk_space() {
    local required_space=2048  # Required space in MB
    local available_space
    available_space=$(df -m /tmp | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "Error: Insufficient disk space in /tmp"
        log "Required: ${required_space}MB, Available: ${available_space}MB"
        return 1
    fi
}

# Function to check current Dataverse version
check_current_version() {
    local version
    version=$(curl -s "http://localhost:8080/api/info/version" | grep -oP '\d+\.\d+')
    if [ "$version" != "$CURRENT_VERSION" ]; then
        log "Error: Current Dataverse version ($version) does not match expected version ($CURRENT_VERSION)"
        return 1
    fi
}

# Function to prompt for backup
prompt_for_backup() {
    log "IMPORTANT: This script will upgrade your Dataverse installation."
    log "Please ensure you have backups of:"
    log "1. Your database"
    log "2. Your configuration files"
    log "3. Your uploaded files"
    echo
    read -p "Have you created all necessary backups? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Please create backups before proceeding with the upgrade."
        exit 1
    fi
}

# Load environment variables from .env file
if [ -f "$(dirname "$0")/.env" ]; then
    log "Loading environment variables from .env file..."
    # shellcheck disable=SC1091
    source "$(dirname "$0")/.env"
else
    log "Error: .env file not found in $(dirname "$0")"
    log "Please copy sample.env to .env and update the values."
    exit 1
fi

# Check disk space
if ! check_disk_space; then
    exit 1
fi

# Check current version
if ! check_current_version; then
    exit 1
fi

# Prompt for backup
prompt_for_backup

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "sed" "awk" "grep" "find" "tar" "unzip" "rsync" "curl" "wget" 
        "pgrep" "systemctl" "sudo" "jq" "bc" "ed" "top"
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
        log "sudo apt-get install sed awk grep find tar unzip rsync curl wget procps systemd jq bc ed procps"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install sed awk grep find tar unzip rsync curl wget procps systemd jq bc ed procps-ng"
        exit 1
    fi
}

# Check for required commands
check_required_commands

# Version information
CURRENT_VERSION="5.14"
TARGET_VERSION="6.0"

# URLs for required software packages
PAYARA_ZIP_URL="https://nexus.payara.fish/repository/payara-community/fish/payara/distributions/payara/6.2023.8/payara-6.2023.8.zip"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.0/dataverse-6.0.war"
SOLR_TAR_URL="https://archive.apache.org/dist/solr/solr/9.3.0/solr-9.3.0.tgz"
DVINSTALL_ZIP_URL="https://github.com/IQSS/dataverse/releases/download/v6.0/dvinstall.zip"
DATAVERSE_UPDATE_FIELDS_URL="https://guides.dataverse.org/en/6.0/_downloads/1158e888bffd60c8a89df32fe90f8181/update-fields.sh"

# Service configuration
PAYARA_SERVICE_FILE="$(systemctl show -p FragmentPath payara.service | cut -d'=' -f2)"

# CPU monitoring configuration for long-running tasks
CPU_THRESHOLD=80  # High CPU usage threshold (percentage)
CHECK_INTERVAL=5  # Seconds between CPU usage checks

# Validate required environment variables
required_vars=(
    "DOMAIN"
    "PAYARA_OLD"
    "PAYARA_NEW"
    "DATAVERSE_USER"
    "SOLR_USER"
    "COUNTER_DAILY_SCRIPT"
    "COUNTER_PROCESSOR_DIR"
    "DATAVERSE_FILE_DIRECTORY"
    "MAIL_HOST"
    "MAIL_USER"
    "MAIL_FROM_ADDRESS"
    "SOLR_PATH"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: Required environment variable $var is not set in .env file"
        exit 1
    fi
done

# Validate service file paths
if [[ -z "$PAYARA_SERVICE_FILE" ]]; then
    log " - Error: payara.service file path not found."
    return 1
fi

SOLR_SERVICE_FILE="$(systemctl show -p FragmentPath solr.service | cut -d'=' -f2)"
if [[ -z "$SOLR_SERVICE_FILE" ]]; then
    log " - Error: solr.service file path not found."
    return 1
fi

# Security check: Prevent running as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    log "This script runs several commands with sudo from within functions."
    exit 1
fi

# Function to undeploy the current Dataverse version
# This ensures a clean deployment of the new version
undeploy_dataverse() {
    log " - Undeploying current Dataverse version..."
    if sudo -u "$DATAVERSE_USER" "$PAYARA_OLD/bin/asadmin" list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
        if ! sudo -u "$DATAVERSE_USER" "$PAYARA_OLD/bin/asadmin" undeploy "dataverse-$CURRENT_VERSION"; then
            log " - Error undeploying Dataverse $CURRENT_VERSION."
            return 1
        fi
    else
        log " - Dataverse $CURRENT_VERSION is not currently deployed. Skipping undeploy step."
    fi
}

# Function to stop Payara server
# Takes a path parameter to handle both old and new Payara installations
stop_payara() {
    local payara_path="$1"
    log " - Stopping Payara at $payara_path..."
    if pgrep -f "payara" > /dev/null; then
        if ! sudo -u "$DATAVERSE_USER" "$payara_path/bin/asadmin" stop-domain; then
            log " - Error stopping Payara."
            return 1
        fi
    else
        log " - Payara is already stopped."
    fi
}

# Function to stop Solr search service
# Ensures clean upgrade of Solr components
stop_solr() {
    log " - Stopping Solr service..."
    if pgrep -f "solr" > /dev/null; then
        if ! sudo systemctl stop solr; then
            log " - Error stopping Solr."
            return 1
        fi
    else
        log " - Solr is already stopped."
    fi
}

# Function to wait for Dataverse to become available
# Polls the site URL until it returns a 200 OK response
wait_for_site() {
    local url="https://${DOMAIN}/dataverse/root?q="
    local response_code

    log " - Waiting for site to become available..."
    
    while true; do
        # Get HTTP response code
        response_code=$(curl -o /dev/null -s -w "%{http_code}" "$url")

        if [[ "$response_code" -eq 200 ]]; then
            log " - Site is up (HTTP 200 OK)."
            break
        else
            log "\r - Waiting... (HTTP response: %s)" "$response_code"
        fi

        # Wait 1 seconds before checking again
        sleep 1
    done
}

# Function to upgrade Java
# Executes the companion upgrade-java.sh script if available
upgrade_java() {
    log " - Upgrading Java..."
    if [ -x "$(dirname "$0")/upgrade-java.sh" ]; then
        log "Running Java upgrade..."
        chmod +x "$(dirname "$0")/upgrade-java.sh"
        "$(dirname "$0")/upgrade-java.sh"
    else
        log "Java upgrade script not found."
        return 1
    fi
}

# Function to download Payara 6
# Downloads the Payara 6 installation package to /tmp
download_payara() {
    log " - Downloading Payara 6..."
    cd /tmp || return 1
    if ! curl -L -O "$PAYARA_ZIP_URL"; then
        log " - Error downloading Payara 6."
        return 1
    fi
}

# Function to install Payara 6
# Extracts the downloaded package and creates necessary symlinks
install_payara() {
    log " - Installing Payara 6..."
    if ! sudo unzip -o "payara-6.2023.8.zip" -d /usr/local/; then
        log " - Error unzipping Payara 6."
        return 1
    fi
    sudo ln -sf /usr/local/payara6 /usr/local/payara
    rm -f "payara-6.2023.8.zip"
}

# Function to configure Payara permissions
# Sets correct ownership for Payara 6 installation
configure_payara_permissions() {
    log " - Configuring Payara permissions..."
    if ! sudo chown -R "$DATAVERSE_USER" /usr/local/payara6; then
        log " - Error setting ownership for Payara 6."
        return 1
    fi
}

# Function to migrate domain.xml and update configurations
migrate_domain_xml() {
    # Get the directory where this script is located
    local script_dir
    script_dir=$(dirname "$(readlink -f "$0")")
    
    # Define paths for domain.xml files
    # domain_xml_local: The new domain.xml template from the upgrade package
    # domain_xml_new: The target location in Payara 6
    # domain_xml_old: The current domain.xml in Payara 5
    local domain_xml_local="$script_dir/6_0_domain.xml"
    local domain_xml_new="$PAYARA_NEW/glassfish/domains/domain1/config/domain.xml"
    local domain_xml_old="$PAYARA_OLD/glassfish/domains/domain1/config/domain.xml"
    
    # Generate backup filename with current date (YYYYMMDD format)
    local current_date=$(date +"%Y%m%d")
    local backup_file="${domain_xml_new}-${current_date}.orig"
    
    # Verify the new domain.xml template exists
    log " - Checking for $domain_xml_local..."
    if [ ! -f "$domain_xml_local" ]; then
        log " - Local domain.xml not found, exiting."
        return 1
    fi
    
    log " - Migrating domain.xml and updating configurations..."

    # Prompt user to create a backup of their current domain.xml
    # This is important as domain.xml contains critical configuration
    read -p "Would you like to backup the domain.xml file before proceeding? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create backup with timestamp
        if ! sudo cp "$domain_xml_new" "$backup_file"; then
            log " - Error backing up new domain.xml."
            return 1
        fi
        log " - Created backup at: $backup_file"
    else
        log " - Skipping backup as requested."
    fi

    # Extract JVM options from the old domain.xml
    # These options are specific to Dataverse and DOI configurations
    local jvm_options
    jvm_options=$(sudo grep -E 'dataverse|doi' "$domain_xml_old" | grep '<jvm-options>' | sed 's/.*<jvm-options>\(.*\)<\/jvm-options>.*/\1/')

    # Insert the extracted JVM options into the new domain.xml
    # This preserves important Dataverse-specific configurations
    sudo awk -v jvm_options="$jvm_options" '
    /<\/java-config>/ {
        print "<jvm-options>" jvm_options "</jvm-options>"
    }
    { print }
    ' "$domain_xml_new" | sudo tee "$domain_xml_new.tmp" > /dev/null

    if [ $? -ne 0 ]; then
        log " - Error inserting JVM options into new domain.xml."
        return 1
    fi

    # Replace the original domain.xml with our updated version
    if ! sudo mv "$domain_xml_new.tmp" "$domain_xml_new"; then
        log " - Error replacing the domain.xml file."
        return 1
    fi

    # Update the file storage directory path in domain.xml
    # This ensures Dataverse knows where to store uploaded files
    if [ -z "$DATAVERSE_FILE_DIRECTORY" ]; then
        log " - Error: DATAVERSE_FILE_DIRECTORY is not set."
        return 1
    fi
    if ! sudo sed -i "s|-Ddataverse.files.file.directory=.*|-Ddataverse.files.file.directory=$DATAVERSE_FILE_DIRECTORY|" "$domain_xml_new"; then
        log " - Error updating file directory path in domain.xml."
        return 1
    fi

    log " - domain.xml successfully migrated and updated."
}


# Function to migrate jhove files
migrate_jhove_files() {
    log " - Migrating jhove configuration files..."
    local config_dir_old="$PAYARA_OLD/glassfish/domains/domain1/config"
    local config_dir_new="$PAYARA_NEW/glassfish/domains/domain1/config"

    if ! sudo rsync -av "$config_dir_old"/jhove* "$config_dir_new/"; then
        log " - Error migrating jhove files."
        return 1
    fi

    # Update jhove.conf to reference payara6
    if ! sudo sed -i 's|payara5|payara6|' "$config_dir_new/jhove.conf"; then
        log " - Error updating jhove.conf."
        return 1
    fi

    if ! sudo chown -R "$DATAVERSE_USER" "$config_dir_new"/jhove*; then
        log " - Error setting ownership for jhove files."
        return 1
    fi
}

# Function to migrate logos
migrate_logos() {
    log " - Migrating logos..."
    local docroot_old="$PAYARA_OLD/glassfish/domains/domain1/docroot"
    local docroot_new="$PAYARA_NEW/glassfish/domains/domain1/docroot"

    if ! sudo -u "$DATAVERSE_USER" rsync -av "$docroot_old/logos/" "$docroot_new/logos/"; then
        log " - Error migrating logos."
        return 1
    fi
}

# Function to migrate MDC logs
migrate_mdc_logs() {
    log " - Migrating MDC logs..."
    local logs_old="$PAYARA_OLD/glassfish/domains/domain1/logs/mdc"
    local logs_new="$PAYARA_NEW/glassfish/domains/domain1/logs/mdc"

    if ! sudo rsync -av "$logs_old" "$logs_new"; then
        log " - Error migrating MDC logs."
        return 1
    fi
}

# Function to update cron jobs and counter processor paths
update_cron_jobs() {
    log " - Updating cron jobs and counter processor paths..."
    if ! sudo sed -i 's|payara5|payara6|' "$COUNTER_DAILY_SCRIPT"; then
        log " - Error updating $COUNTER_DAILY_SCRIPT."
        return 1
    fi

    if [ -d "$COUNTER_PROCESSOR_DIR" ]; then
        if ! sudo find "$COUNTER_PROCESSOR_DIR" -type f -exec sed -i 's|/payara5/|/payara6/|g' {} +; then
            log " - Error updating counter processor paths."
            return 1
        fi
    fi
}

# Function to update Payara service
update_payara_service() {
    local backup_file="$PAYARA_SERVICE_FILE.bak"

    log " - Updating Payara service..."

    # Validate the service file exists
    if [[ ! -f "$PAYARA_SERVICE_FILE" ]]; then
        log " - Service file not found: %s" "$PAYARA_SERVICE_FILE"
        return 1
    fi

    # Create a backup of the service file
    if ! sudo cp "$PAYARA_SERVICE_FILE" "$backup_file"; then
        log " - Error creating backup of %s." "$PAYARA_SERVICE_FILE"
        return 1
    fi

    # Perform the sed replacement
    if ! sudo sed -i 's|payara5|payara6|' "$PAYARA_SERVICE_FILE"; then
        log " - Error updating %s." "$PAYARA_SERVICE_FILE"
        return 1
    fi

    # Reload systemd and restart the service with proper error handling
    if ! sudo systemctl daemon-reload; then
        log " - Error reloading systemd daemon."
        return 1
    fi

    if ! sudo systemctl stop payara; then
        log " - Error stopping Payara service."
        return 1
    fi

    if ! sudo systemctl start payara; then
        log " - Error starting Payara service."
        return 1
    fi

    log " - Payara service updated and restarted successfully."
    return 0
}

# Function to start Payara 6
start_payara6() {
    log " - Starting Payara 6..."
    if ! sudo systemctl start payara; then
        log " - Error starting Payara 6."
        return 1
    fi
}

# Function to create JavaMail resource
create_javamail_resource() {
    log " - Creating JavaMail resource..."
    local output
    if ! output=$(sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" create-javamail-resource --mailhost "$MAIL_HOST" --mailuser "$MAIL_USER" --fromaddress "$MAIL_FROM_ADDRESS" mail/notifyMailSession 2>&1); then
        if [[ "$output" == *"already exists with resource-ref"* ]]; then
            log " - JavaMail resource already exists. Proceeding..."
        else
            log " - Error creating JavaMail resource: $output"
            return 1
        fi
    fi
}

# Function to create password aliases
create_password_aliases() {
    log " - Checking existing password aliases..."

    # Check for existing aliases
    local alias_list
    alias_list=$(sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" list-password-aliases)

    # Flags to track whether we need to create aliases
    local db_alias_exists=false
    local doi_alias_exists=false

    # Check if dataverse.db.password alias exists
    if echo "$alias_list" | grep -q "dataverse.db.password"; then
        log " - Database password alias 'dataverse.db.password' already exists."
        db_alias_exists=true
    fi

    # Check if doi_password_alias alias exists
    if echo "$alias_list" | grep -q "doi_password_alias"; then
        log " - DOI password alias 'doi_password_alias' already exists."
        doi_alias_exists=true
    fi

    # If both aliases exist, no need to proceed further
    if $db_alias_exists && $doi_alias_exists; then
        log " - Both password aliases already exist. No need to create new ones."
        return 0
    fi

    # Create missing database password alias
    if ! $db_alias_exists; then
        read -s -p "Enter database password: " DB_PASSWORD
        echo
        if [[ -z "$DB_PASSWORD" ]]; then
            log " - Error: Database password cannot be blank."
            return 1
        fi

        # Write to temporary file and create alias
        echo "AS_ADMIN_ALIASPASSWORD=$DB_PASSWORD" > /tmp/dataverse.db.password.txt
        if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" create-password-alias dataverse.db.password --passwordfile /tmp/dataverse.db.password.txt; then
            log " - Error creating database password alias."
            rm -f /tmp/dataverse.db.password.txt
            return 1
        fi
        rm -f /tmp/dataverse.db.password.txt
        log " - Database password alias 'dataverse.db.password' created successfully."
    else
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" update-password-alias dataverse.db.password; then
            log " - Error creating database password alias."
            rm -f /tmp/dataverse.db.password.txt
            return 1
        fi
        log " - Database password alias 'dataverse.db.password' updated successfully."
    fi

    # Create missing DOI password alias (optional)
    if ! $doi_alias_exists; then
        read -s -p "Enter DOI password (if applicable, or press Enter to skip): " DOI_PASSWORD
        echo
        if [[ -n "$DOI_PASSWORD" ]]; then
            echo "AS_ADMIN_ALIASPASSWORD=$DOI_PASSWORD" > /tmp/dataverse.doi.password.txt
            if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" create-password-alias doi_password_alias --passwordfile /tmp/dataverse.doi.password.txt; then
                log " - Error creating DOI password alias."
                rm -f /tmp/dataverse.doi.password.txt
                return 1
            fi
            rm -f /tmp/dataverse.doi.password.txt
            log " - DOI password alias 'doi_password_alias' created successfully."
        else
            log " - Skipping DOI password alias creation."
        fi
    fi

    # Final check to ensure both aliases are created
    alias_list=$(sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" list-password-aliases)
    if ! echo "$alias_list" | grep -q "dataverse.db.password"; then
        log " - Error: Database password alias was not created."
        return 1
    fi
    if ! echo "$alias_list" | grep -q "doi_password_alias"; then
        log " - Error: DOI password alias was not created."
        return 1
    fi

    log " - All required password aliases are set."
}



# Function to create JVM options and restart Payara
create_jvm_options() {
    log " - Creating JVM options..."
    local output
    if ! output=$(sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" create-jvm-options --add-opens=java.base/java.io=ALL-UNNAMED 2>&1); then
        if [[ "$output" == *"already exists in the configuration"* ]]; then
            log " - JVM option already exists. Proceeding..."
        else
            log " - Error creating JVM options: $output"
            return 1
        fi
    fi

    log " - Restarting Payara 6..."
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" stop-domain; then
        log " - Error stopping Payara 6."
        return 1
    fi
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" start-domain; then
        log " - Error starting Payara 6."
        return 1
    fi
}


# Function to create network listener
create_network_listener() {
    log " - Creating network listener..."
    local output
    if ! output=$(sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" create-network-listener --protocol http-listener-1 --listenerport 8009 --jkenabled true jk-connector 2>&1); then
        if [[ "$output" == *"already exists"* ]]; then
            log " - Network listener 'jk-connector' already exists. Proceeding..."
        else
            log " - Error creating network listener: $output"
            return 1
        fi
    fi
}

# Function to deploy Dataverse
# Downloads and deploys the new Dataverse WAR file to Payara 6
deploy_dataverse() {
    log " - Deploying Dataverse..."
    cd /tmp || return 1
    
    # Download the new Dataverse WAR file
    if ! wget "$DATAVERSE_WAR_URL"; then
        log " - Error downloading Dataverse WAR file."
        return 1
    fi

    # Copy WAR file to dataverse user's home directory
    if ! sudo cp "dataverse-$TARGET_VERSION.war" "/home/$DATAVERSE_USER/"; then
        log " - Error copying WAR file to /home/$DATAVERSE_USER/."
        rm -f "dataverse-$TARGET_VERSION.war"
        return 1
    fi
    sudo chown "$DATAVERSE_USER:" "/home/$DATAVERSE_USER/dataverse-$TARGET_VERSION.war"

    # Deploy the WAR file using Payara's asadmin tool
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" deploy "/home/$DATAVERSE_USER/dataverse-$TARGET_VERSION.war"; then
        if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" deploy "dataverse-$TARGET_VERSION"; then
            log -e " - Error deploying Dataverse WAR file.\n"
            rm -f "dataverse-$TARGET_VERSION.war"
            return 1
        fi
    fi
    rm -f "dataverse-$TARGET_VERSION.war"
}

# Function to verify Dataverse version
# Checks the API endpoint to confirm successful upgrade
check_dataverse_version() {
    log " - Checking Dataverse version..."
    local version
    version=$(curl -s "http://localhost:8080/api/info/version" | grep -oP '\d+\.\d+')
    if [ "$version" == "$TARGET_VERSION" ]; then
        log " - Dataverse upgraded to version $TARGET_VERSION successfully."
    else
        log " - Dataverse version check failed. Expected $TARGET_VERSION, got $version."
        return 1
    fi
}

# Function to restart Payara 6
# Ensures all new configurations are loaded
restart_payara6() {
    log " - Restarting Payara 6..."
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" stop-domain; then
        log " - Error stopping Payara 6."
        return 1
    fi
    if ! sudo -u "$DATAVERSE_USER" "$PAYARA_NEW/bin/asadmin" start-domain; then
        log " - Error starting Payara 6."
        return 1
    fi
}

# Function to download dvinstall package
# Downloads and extracts the Dataverse installation utilities
download_dvinstall() {
    log " - Downloading dvinstall..."
    cd /tmp || return 1
    if ! wget "$DVINSTALL_ZIP_URL"; then
        log " - Error downloading dvinstall.zip."
        return 1
    fi
    if ! unzip -o dvinstall.zip; then
        log " - Error unzipping dvinstall.zip."
        rm -f dvinstall.zip
        return 1
    fi
    rm -f dvinstall.zip
}

# Function to upgrade Solr
# Handles the upgrade of Solr from version 8 to 9.3.0
upgrade_solr() {
    log " - Upgrading Solr..."
    
    # Handle existing Solr installation
    if [ -L "$SOLR_PATH" ]; then
        if ! sudo rm "$SOLR_PATH"; then
            log " - Error removing old Solr symlink."
            return 1
        fi
    else
        if ! sudo mv "$SOLR_PATH" "${SOLR_PATH}-8-${current_date}"; then
            log " - Error moving old Solr directory."
            return 1
        fi
    fi

    # Download and extract new Solr version
    cd /tmp || return 1
    if ! wget "$SOLR_TAR_URL"; then
        log " - Error downloading Solr tarball."
        return 1
    fi

    if ! tar xvzf "solr-9.3.0.tgz"; then
        log " - Error extracting Solr tarball."
        rm -f "solr-9.3.0.tgz"
        return 1
    fi

    if ! sudo mv "solr-9.3.0" "${SOLR_PATH}-9.3.0"; then
        log " - Error moving Solr directory."
        rm -rf "solr-9.3.0"
        rm -f "solr-9.3.0.tgz"
        return 1
    fi
    rm -f "solr-9.3.0.tgz"

    if ! sudo ln -sf "${SOLR_PATH}-9.3.0" ${SOLR_PATH}; then
        log " - Error creating Solr symlink."
        return 1
    fi
}

# Function to update Solr configurations
update_solr_configs() {
    log " - Updating Solr configurations..."
    if ! sudo rsync -avz "${SOLR_PATH}/server/solr/configsets/_default/" "${SOLR_PATH}/server/solr/collection1"; then
        log " - Error copying Solr configsets."
        return 1
    fi

    if ! sudo rsync -avz /tmp/dvinstall/schema*.xml "${SOLR_PATH}/server/solr/collection1/conf/"; then
        log " - Error copying Solr schema files."
        return 1
    fi

    if ! sudo cp "/tmp/dvinstall/solrconfig.xml" "${SOLR_PATH}/server/solr/collection1/conf/solrconfig.xml"; then
        log " - Error copying Solr solrconfig.xml."
        return 1
    fi
}

# Function to update Jetty configuration
update_jetty_config() {
    log " - Updating Jetty configuration..."
    local jetty_file="${SOLR_PATH}-9.3.0/server/etc/jetty.xml"

    if ! sudo sed -i 's/\(<Set name="requestHeaderSize">.*default="\)[^"]*\("\)/\1102400\2/' "$jetty_file"; then
        log " - Error updating Jetty requestHeaderSize."
        return 1
    fi
}

# Function to configure Solr core
configure_solr_core() {
    log " - Configuring Solr core..."
    if ! sudo touch "${SOLR_PATH}/server/solr/collection1/core.properties"; then
        log " - Error creating core.properties."
        return 1
    fi

    echo "name=collection1" | sudo tee "${SOLR_PATH}/server/solr/collection1/core.properties" > /dev/null

    if ! sudo chown -R "$SOLR_USER:" "${SOLR_PATH}-9.3.0/"; then
        log " - Error setting ownership for Solr directories."
        return 1
    fi
}

# Function to update Solr service
update_solr_service() {
    log " - Updating Solr service..."
    local solr_service_file="$SOLR_SERVICE_FILE"

    # Escape the path for sed
    local escaped_solr_path=$(echo "$SOLR_PATH" | sed 's/[\/&]/\\&/g')

    if ! sudo sed -i "s#^WorkingDirectory *= *.*#WorkingDirectory=$SOLR_PATH#" "$solr_service_file"; then
        log " - Error updating WorkingDirectory in solr.service."
        return 1
    fi

    if ! sudo sed -i "s#^ExecStart *= *.*#ExecStart=$SOLR_PATH/bin/solr#" "$solr_service_file"; then
        log " - Error updating ExecStart in solr.service."
        return 1
    fi

    if ! sudo sed -i "s#^ExecStop *= *.*#ExecStop=$SOLR_PATH/bin/solr#" "$solr_service_file"; then
        log " - Error updating ExecStop in solr.service."
        return 1
    fi

    sudo systemctl daemon-reload
}

# Function to start Solr service
# Starts Solr and verifies it's running correctly
start_solr_service() {
    log " - Starting Solr service..."
    if ! sudo systemctl start solr; then
        log " - Error starting Solr service."
        return 1
    fi

    # Verify Solr is responding to requests
    if ! curl -s "http://localhost:8983/solr/collection1/schema/fields" > /dev/null; then
        log " - Error: Solr is not responding as expected."
        return 1
    fi
}

# Function to update Solr schema
# Updates the Solr schema to match new Dataverse requirements
update_solr_schema() {
    log " - Updating Solr schema..."
    cd /tmp || return 1
    
    # Download the schema update script
    if ! wget "$DATAVERSE_UPDATE_FIELDS_URL"; then
        log " - Error downloading update-fields.sh."
        return 1
    fi

    # Set proper permissions for the update script
    sudo chown "$SOLR_USER:" update-fields.sh
    sudo chmod +x update-fields.sh

    # Install required 'ed' editor
    # Detect package manager and install ed
    if command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get install -y ed; then
            log " - Error installing 'ed' editor."
            return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! sudo yum install -y ed; then
            log " - Error installing 'ed' editor."
            return 1
        fi
    else
        log " - Error: No supported package manager found."
        return 1
    fi

    # Update the schema and reload the core
    if ! sudo -u "$SOLR_USER" bash -c 'curl "http://localhost:8080/api/admin/index/solr/schema" | ./update-fields.sh /usr/local/solr/server/solr/collection1/conf/schema.xml'; then
        log " - Error updating Solr schema."
        return 1
    fi

    if ! sudo -u "$SOLR_USER" bash -c 'curl "http://localhost:8983/solr/admin/cores?action=RELOAD&core=collection1"'; then
        log " - Error reloading Solr core."
        return 1
    fi

    # Verify the index is accessible
    if ! curl -s "http://localhost:8080/api/admin/index" | jq > /dev/null; then
        log " - Error verifying Solr index."
        return 1
    fi
}

# Function to get current CPU usage
# Calculates CPU usage percentage from top command output
get_cpu_usage() {
    local cpu_idle; cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/")
    printf "%.0f\n" "$(echo "100 - $cpu_idle" | bc)"
}

# Function to monitor CPU usage during long-running tasks
# Continuously monitors CPU usage until it drops below threshold
monitor_cpu() {
    while :; do
        local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local current_cpu; current_cpu=$(get_cpu_usage)
        
        printf "\r[%s] Dataverse is running several update tasks, CPU usage: %s%%" "$timestamp" "$current_cpu"
        
        if [[ $current_cpu -lt $CPU_THRESHOLD ]]; then
            printf "\n[%s] Task has completed. CPU usage is back to normal.\n" "$timestamp"
            return
        fi
        sleep "$CHECK_INTERVAL"
    done
}

# Main function
# Orchestrates the entire upgrade process
main() {
    # Set Payara environment variable for the upgrade process
    export PAYARA="$PAYARA_NEW"

    # Step 1: Undeploy current version
    log -e "\nStep 1: Undeploy the existing Dataverse version"
    if ! undeploy_dataverse; then
        log -e " - Error during undeploy.\n"
        exit 1
    fi

    # Step 2: Stop Payara 5
    log -e "\nStep 2: Stop Payara 5"
    if ! stop_payara "$PAYARA_OLD"; then
        log -e " - Error stopping Payara 5.\n"
        exit 1
    fi

    # Step 3: Stop Solr
    log -e "\nStep 3: Stop Solr"
    if ! stop_solr; then
        log -e " - Error stopping Solr.\n"
        exit 1
    fi

    # Step 4: Upgrade Java
    log -e "\nStep 4: Upgrade Java"
    if ! upgrade_java; then
        log -e " - Error upgrading Java.\n"
        exit 1
    fi

    log -e "\nStep 5: Download Payara 6"
    if ! download_payara; then
        log -e " - Error downloading Payara 6.\n"
        exit 1
    fi

    log -e "\nStep 6: Install Payara 6"
    if ! install_payara; then
        log -e " - Error installing Payara 6.\n"
        exit 1
    fi

    log -e "\nStep 7: Configure Payara permissions"
    if ! configure_payara_permissions; then
        log -e " - Error configuring Payara permissions.\n"
        exit 1
    fi

    log -e "\nStep 8: Migrate domain.xml"
    if ! migrate_domain_xml; then
        log -e " - Error migrating domain.xml.\n"
        exit 1
    fi

    log -e "\nStep 9: Migrate jhove files"
    if ! migrate_jhove_files; then
        log -e " - Error migrating jhove files.\n"
        exit 1
    fi

    log -e "\nStep 10: Migrate logos"
    if ! migrate_logos; then
        log -e " - Error migrating logos.\n"
        exit 1
    fi

    log -e "\nStep 11: Migrate MDC logs"
    if ! migrate_mdc_logs; then
        log -e " - Error migrating MDC logs.\n"
        exit 1
    fi

    log -e "\nStep 12: Update cron jobs and counter processor paths"
    if ! update_cron_jobs; then
        log -e " - Error updating cron jobs.\n"
        exit 1
    fi

    log -e "\nStep 13: Update Payara service"
    if ! update_payara_service; then
        log -e " - Error updating Payara service.\n"
        exit 1
    fi

    log -e "\nStep 14: Start Payara 6"
    if ! start_payara6; then
        log -e " - Error starting Payara 6.\n"
        exit 1
    fi

    log -e "\nStep 15: Create JavaMail resource"
    if ! create_javamail_resource; then
        log -e " - Error creating JavaMail resource.\n"
        exit 1
    fi

    log -e "\nStep 16: Create password aliases"
    if ! create_password_aliases; then
        log -e " - Error creating password aliases.\n"
        exit 1
    fi

    log -e "\nStep 17: Create JVM options and restart Payara"
    if ! create_jvm_options; then
        log -e " - Error creating JVM options.\n"
        exit 1
    fi

    log -e "\nStep 18: Create network listener"
    if ! create_network_listener; then
        log -e " - Error creating network listener.\n"
        exit 1
    fi

    log -e "\nStep 19: Deploy Dataverse"
    if ! deploy_dataverse; then
        log -e " - Error deploying Dataverse.\n"
        exit 1
    fi

    log -e "\nWait for Payara to come up."
    wait_for_site

    log -e "\nStep 11 2nd part: Migrate MDC logs"
    log " - Setting MDC path in config"
    curl -X PUT -d "$logs_new" http://localhost:8080/api/admin/settings/:MDCLogPath || return 1

    log -e "\nStep 20: Check Dataverse version"
    if ! check_dataverse_version; then
        log -e " - Error checking Dataverse version.\n"
        exit 1
    fi

    log -e "\nStep 21: Restart Payara 6"
    if ! restart_payara6; then
        log -e " - Error restarting Payara 6.\n"
        exit 1
    fi

    log -e "\nStep 22: Download dvinstall"
    if ! download_dvinstall; then
        log -e " - Error downloading dvinstall.\n"
        exit 1
    fi

    log "Solr Step 1: Upgrade Solr"
    if ! upgrade_solr; then
        log -e " - Error upgrading Solr.\n"
        exit 1
    fi

    log "Solr Step 2: Update Solr configurations"
    if ! update_solr_configs; then
        log -e " - Error updating Solr configurations.\n"
        exit 1
    fi

    log "Solr Step 3: Update Jetty configuration"
    if ! update_jetty_config; then
        log -e " - Error updating Jetty configuration.\n"
        exit 1
    fi

    log "Solr Step 4: Configure Solr core"
    if ! configure_solr_core; then
        log -e " - Error configuring Solr core.\n"
        exit 1
    fi

    log "Solr Step 5: Update Solr service"
    if ! update_solr_service; then
        log -e " - Error updating Solr service.\n"
        exit 1
    fi

    log "Solr Step 6: Start Solr service"
    if ! start_solr_service; then
        log -e " - Error starting Solr service.\n"
        exit 1
    fi

    log "Solr Step 7: Update Solr schema"
    if ! update_solr_schema; then
        log -e " - Error updating Solr schema.\n"
        exit 1
    fi

    log "\n\nUpgrade to Dataverse %s completed successfully.\n\n" "$TARGET_VERSION"

    # Not needed but can be used to monitor CPU usage to see when it's done.
    monitor_cpu
}

# Run the main function
main "$@"