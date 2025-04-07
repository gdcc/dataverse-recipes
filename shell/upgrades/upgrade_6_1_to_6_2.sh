#!/bin/bash
# Used release to generate this: https://github.com/IQSS/dataverse/releases/tag/v6.2

# Logging configuration
LOGFILE="dataverse_upgrade_6_1_to_6_2.log"

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

# Load environment variables from .env file
if [[ -f ".env" ]]; then
    source ".env"
    log "Loaded environment variables from .env file"
else
    log "Error: .env file not found. Please create one based on sample.env"
    exit 1
fi

# Required variables check
if [[ -z "$DOMAIN" || -z "$PAYARA" || -z "$DATAVERSE_USER" || -z "$BASHRC_FILE" || -z "$SOLR_SCHEMA_PATH" ]]; then
    log "Error: Required environment variables are not set in .env file."
    log "Please ensure DOMAIN, PAYARA, DATAVERSE_USER, and BASHRC_FILE are defined."
    exit 1
fi

SOLR_SCHEMA_URL="https://raw.githubusercontent.com/IQSS/dataverse/v6.2/conf/solr/9.3.0/schema.xml"
SOLR_SCHEMA_FILE=$(basename "$SOLR_SCHEMA_URL")
SOLR_SCHEMA_FILE="/tmp/$SOLR_SCHEMA_FILE"
DATAVERSE_WAR_URL="https://github.com/IQSS/dataverse/releases/download/v6.2/dataverse-6.2.war"
DATAVERSE_WAR_HASH="d0c8c62025457e35333ec7c9bf896355ffeb3b6823020da5f53599b72f399d2e"
GEOSPATIAL_URL="https://github.com/IQSS/dataverse/releases/download/v6.2/geospatial.tsv"
GEOSPATIAL_FILE="/tmp/geospatial.tsv"
CITATION_URL="https://github.com/IQSS/dataverse/releases/download/v6.2/citation.tsv"
CITATION_FILE="/tmp/citation.tsv"
ASTROPHYSICS_URL="https://github.com/IQSS/dataverse/releases/download/v6.2/astrophysics.tsv"
ASTROPHYSICS_FILE="/tmp/astrophysics.tsv"
BIOMEDICAL_URL="https://github.com/IQSS/dataverse/releases/download/v6.2/biomedical.tsv"
BIOMEDICAL_FILE="/tmp/biomedical.tsv"
SOLR_FIELD_UPDATER_URL="https://raw.githubusercontent.com/IQSS/dataverse/refs/tags/v6.2/conf/solr/9.3.0/update-fields.sh"
SOLR_FIELD_UPDATER_FILE="/tmp/update-fields.sh"
DEPLOY_DIR="$PAYARA/glassfish/domains/domain1/generated"
DATAVERSE_WAR_FILENAME="dataverse-6.2.war"
DATAVERSE_WAR_FILE="$DEPLOY_DIR/$DATAVERSE_WAR_FILENAME"
CURRENT_VERSION="6.1"
TARGET_VERSION="6.2"
PAYARA_EXPORT_LINE="export PAYARA=\"$PAYARA\""
RATE_LIMIT_JSON_FILE="rate-limit-actions-setting.json"

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
cleanup_temp_files() {
    log "Cleaning up temporary files..."
    # Clean up all potential temporary files
    sudo rm -f "$GEOSPATIAL_FILE"
    sudo rm -f "$CITATION_FILE"
    sudo rm -f "$ASTROPHYSICS_FILE"
    sudo rm -f "$BIOMEDICAL_FILE"
    sudo rm -f "$SOLR_FIELD_UPDATER_FILE"
    sudo rm -f "$SOLR_SCHEMA_FILE"
    sudo rm -f "tmp/$DATAVERSE_WAR_FILENAME"
    log "Cleanup complete."
}

# Register cleanup function to run on script exit
trap cleanup_temp_files EXIT

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "grep" "sed" "sudo" "systemctl" "pgrep" 
        "jq" "rm" "chown" "chmod" "bash" "tee" "shasum"
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
        log "sudo apt-get install curl grep sed sudo systemctl pgrep jq rm coreutils bash tee"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install curl grep sed sudo systemctl pgrep jq coreutils bash tee"
        exit 1
    fi
}

check_current_version() {
    local version response
    log "Checking current Dataverse version..."
    response=$(sudo -u dataverse $PAYARA/bin/asadmin list-applications)

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

# Function to undeploy the current Dataverse version
undeploy_dataverse() {
    if sudo -u dataverse $PAYARA/bin/asadmin list-applications | grep -q "dataverse-$CURRENT_VERSION"; then
        log "Undeploying current Dataverse version..."
        sudo -u dataverse $PAYARA/bin/asadmin undeploy dataverse-$CURRENT_VERSION || return 1
        log "Undeploy completed successfully."
    else
        log "Dataverse is not currently deployed. Skipping undeploy step."
    fi
}

# Function to stop Payara service
stop_payara() {
    if pgrep -f payara > /dev/null; then
        log "Stopping Payara service..."
        sudo systemctl stop payara || return 1
        log "Payara service stopped."
    else
        log "Payara is already stopped."
    fi
}

check_mdc_displayed() {
    # Check to see if MDC is displayed
    log "Checking if MDC is displayed..."
    local response
    response=$(sudo -u $DATAVERSE_USER curl -s http://localhost:8080/api/admin/settings/:DisplayMDCMetrics)
    if [[ "$response" == "true" ]]; then
        log "MDC display is enabled."
        return 1
    else
        log "MDC display is not enabled."
        return 0
    fi
}

stop_solr() {
    if pgrep -f solr > /dev/null; then
        log "Stopping Solr service..."
        sudo systemctl stop solr || return 1
        log "Solr service stopped."
    else
        log "Solr is already stopped."
    fi
}

start_solr() {
    if ! pgrep -f solr > /dev/null; then
        log "Starting Solr service..."
        sudo systemctl start solr || return 1
        log "Solr service started."
    else
        log "Solr is already running."
    fi
}

# Function to start Payara service
start_payara() {
    if ! pgrep -f payara > /dev/null; then
        log "Starting Payara service..."
        sudo systemctl start payara || return 1
        log "Payara service started."
    else
        log "Payara is already running."
    fi
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

download_war_file() {
    if [[ -f "$DATAVERSE_WAR_FILE" ]]; then
        log "WAR file already exists at $DATAVERSE_WAR_FILE. Skipping download."
        ACTUAL_HASH=$(sudo -u dataverse shasum -a 256 "$DATAVERSE_WAR_FILE" | awk '{print $1}')
        if [ "$ACTUAL_HASH" != "$DATAVERSE_WAR_HASH" ]; then
            log "Hash mismatch!"
            rm -f $DATAVERSE_WAR_FILE
        else
            log "Hash matches!"
            return 0
        fi
    fi
    log "WAR file not found or its hash didn't match. Downloading..."
    sudo rm -f "$DATAVERSE_WAR_FILE"
    if ! sudo -u dataverse curl -L -o "tmp/$DATAVERSE_WAR_FILENAME" "$DATAVERSE_WAR_URL"; then
        log "Error downloading the WAR file."
        return 1
    fi
    log "Download completed successfully."
    sudo install -u $DATAVERSE_USER -g $DATAVERSE_USER_GROUP -m 644 "$DATAVERSE_WAR_FILENAME" "$DATAVERSE_WAR_FILE" || return 1
    ACTUAL_HASH=$(sudo -u dataverse shasum -a 256 "$DATAVERSE_WAR_FILE" | awk '{print $1}')
    if [ "$ACTUAL_HASH" != "$DATAVERSE_WAR_HASH" ]; then
        log "Hash mismatch!"
        return 1
    else
        log "Hash matches!"
        sudo rm -f "tmp/$DATAVERSE_WAR_FILENAME"
    fi
}

download_solr_schema_file() {
    if [[ -f "$SOLR_SCHEMA_FILE" ]]; then
        log "SOLR_SCHEMA file already exists at $SOLR_SCHEMA_FILE. Skipping download."
    else
        log "SOLR_SCHEMA file not found. Downloading..."
        if curl -L -o "$SOLR_SCHEMA_FILE" "$SOLR_SCHEMA_URL"; then
            log "SOLR_SCHEMA file downloaded successfully to $SOLR_SCHEMA_FILE"
        else
            log "Error downloading the SOLR_SCHEMA file. Exiting script."
            return 1
        fi
    fi
}

update_solr_schema_file() {
    if [[ -f "$SOLR_SCHEMA_FILE" ]]; then
        log "Solr schema file found. Uploading..."
        sudo cp $SOLR_SCHEMA_PATH ${SOLR_SCHEMA_PATH}_$(date +"%Y%m%d") || return 1
        sudo chmod --reference=${SOLR_SCHEMA_PATH}_$(date +"%Y%m%d") $SOLR_SCHEMA_PATH || return 1
        sudo chown --reference=${SOLR_SCHEMA_PATH}_$(date +"%Y%m%d") $SOLR_SCHEMA_PATH || return 1
        if ! sudo cp $SOLR_SCHEMA_FILE $SOLR_SCHEMA_PATH ; then
            log "Error copying with the Solr schema file."
            return 1
        fi
        log "Update completed successfully."
        sudo rm -f $SOLR_SCHEMA_FILE
    else
        log "Solr schema file is missing at $SOLR_SCHEMA_FILE."
        return 1
    fi
}

download_geospatial_file() {
    if [[ -f "$GEOSPATIAL_FILE" ]]; then
        log "Geospatial file already exists at $GEOSPATIAL_FILE. Skipping download."
    else
        log "Geospatial file not found. Downloading..."
        if sudo -u dataverse bash -c "curl -L -o \"$GEOSPATIAL_FILE\" \"$GEOSPATIAL_URL\""; then
            log "Geospatial file downloaded successfully to $GEOSPATIAL_FILE"
        else
            log "Error downloading the Geospatial file. Exiting script."
            return 1
        fi
    fi
}

update_geospatial_metadata_block() {
    if [[ -f "$GEOSPATIAL_FILE" ]]; then
        log "Geospatial file found. Uploading..."
        
        # Capture the curl output
        local response
        response=$(sudo -u dataverse curl -s http://localhost:8080/api/admin/datasetfield/load \
            -H "Content-type: text/tab-separated-values" \
            -X POST --upload-file "$GEOSPATIAL_FILE")

        # Check if "The requested resource is not available" is in the response
        if echo "$response" | grep -q "The requested resource is not available"; then
            log "Error: The requested resource is not available."
            return 1
        fi

        # Check for any other curl errors
        if [[ $? -ne 0 ]]; then
            log "Error updating with the Geospatial file."
            return 1
        fi

        log "Update completed successfully."
        sudo rm -f "$GEOSPATIAL_FILE"
    else
        log "Geospatial file is missing at $GEOSPATIAL_FILE."
        return 1
    fi
}

download_citation_file() {
    if [[ -f "$CITATION_FILE" ]]; then
        log "Citation file already exists at $CITATION_FILE. Skipping download."
    else
        log "Citation file not found. Downloading..."
        if sudo -u dataverse bash -c "curl -L -o \"$CITATION_FILE\" \"$CITATION_URL\""; then
            log "Citation file downloaded successfully to $CITATION_FILE"
        else
            log "Error downloading the Citation file. Exiting script."
            return 1
        fi
    fi
}

update_citation_metadata_block() {
    if [[ -f "$CITATION_FILE" ]]; then
        log "Citation file found. Uploading..."
        
        # Capture the curl output
        local response
        response=$(sudo -u dataverse curl -s http://localhost:8080/api/admin/datasetfield/load \
            -H "Content-type: text/tab-separated-values" \
            -X POST --upload-file "$CITATION_FILE")

        # Check if "The requested resource is not available" is in the response
        if echo "$response" | grep -q "The requested resource is not available"; then
            log "Error: The requested resource is not available."
            return 1
        fi

        # Check for any other curl errors
        if [[ $? -ne 0 ]]; then
            log "Error updating with the Citation file."
            return 1
        fi

        log "Update completed successfully."
        sudo rm -f "$CITATION_FILE"
    else
        log "Citation file is missing at $CITATION_FILE."
        return 1
    fi
}

download_astrophysics_file() {
    if [[ -f "$ASTROPHYSICS_FILE" ]]; then
        log "ASTROPHYSICS file already exists at $ASTROPHYSICS_FILE. Skipping download."
    else
        log "ASTROPHYSICS file not found. Downloading..."
        if sudo -u dataverse bash -c "curl -L -o \"$ASTROPHYSICS_FILE\" \"$ASTROPHYSICS_URL\""; then
            log "ASTROPHYSICS file downloaded successfully to $ASTROPHYSICS_FILE"
        else
            log "Error downloading the ASTROPHYSICS file. Exiting script."
            return 1
        fi
    fi
}

update_astrophysics_metadata_block() {
    if [[ -f "$ASTROPHYSICS_FILE" ]]; then
        log "ASTROPHYSICS file found. Uploading..."
        
        # Capture the curl output
        local response
        response=$(sudo -u dataverse curl -s http://localhost:8080/api/admin/datasetfield/load \
            -H "Content-type: text/tab-separated-values" \
            -X POST --upload-file "$ASTROPHYSICS_FILE")

        # Check if "The requested resource is not available" is in the response
        if echo "$response" | grep -q "The requested resource is not available"; then
            log "Error: The requested resource is not available."
            return 1
        fi

        # Check for any other curl errors
        if [[ $? -ne 0 ]]; then
            log "Error updating with the ASTROPHYSICS file."
            return 1
        fi

        log "Update completed successfully."
        sudo rm -f "$ASTROPHYSICS_FILE"
    else
        log "ASTROPHYSICS file is missing at $ASTROPHYSICS_FILE."
        return 1
    fi
}

download_biomedical_file() {
    if [[ -f "$BIOMEDICAL_FILE" ]]; then
        log "BIOMEDICAL file already exists at $BIOMEDICAL_FILE. Skipping download."
    else
        log "BIOMEDICAL file not found. Downloading..."
        if sudo -u dataverse bash -c "curl -L -o \"$BIOMEDICAL_FILE\" \"$BIOMEDICAL_URL\""; then
            log "BIOMEDICAL file downloaded successfully to $BIOMEDICAL_FILE"
        else
            log "Error downloading the BIOMEDICAL file. Exiting script."
            return 1
        fi
    fi
}

update_biomedical_metadata_block() {
    if [[ -f "$BIOMEDICAL_FILE" ]]; then
        log "BIOMEDICAL file found. Uploading..."
        
        # Capture the curl output
        local response
        response=$(sudo -u dataverse curl -s http://localhost:8080/api/admin/datasetfield/load \
            -H "Content-type: text/tab-separated-values" \
            -X POST --upload-file "$BIOMEDICAL_FILE")

        # Check if "The requested resource is not available" is in the response
        if echo "$response" | grep -q "The requested resource is not available"; then
            log "Error: The requested resource is not available."
            return 1
        fi

        # Check for any other curl errors
        if [[ $? -ne 0 ]]; then
            log "Error updating with the BIOMEDICAL file."
            return 1
        fi

        log "Update completed successfully."
        sudo rm -f "$BIOMEDICAL_FILE"
    else
        log "BIOMEDICAL file is missing at $BIOMEDICAL_FILE."
        return 1
    fi
}

# Download and update Solr schema updater
download_solr_schema_updater() {
    if [[ -f "$SOLR_FIELD_UPDATER_FILE" ]]; then
        log "Solr Field Updater file already exists at $SOLR_FIELD_UPDATER_FILE. Skipping download."
    else
        log "Solr Field Updater file not found. Downloading..."
        if sudo -u solr bash -c "curl -L -o \"$SOLR_FIELD_UPDATER_FILE\" \"$SOLR_FIELD_UPDATER_URL\""; then
            log "Solr Field Updater file downloaded successfully to $SOLR_FIELD_UPDATER_FILE"
        else
            log "Error downloading the Solr Field Updater file. Exiting script."
            return 1
        fi
    fi
    if ! sudo chmod +x $SOLR_FIELD_UPDATER_FILE; then
        log "Error running chmod on $SOLR_FIELD_UPDATER_FILE"
        return 1
    fi
    if ! sudo chown solr:solr $SOLR_FIELD_UPDATER_FILE; then
        log "Error running chown on $SOLR_FIELD_UPDATER_FILE"
        return 1
    fi
}

update_solr_schema_updater() {
    if [[ -f "$SOLR_FIELD_UPDATER_FILE" ]]; then
        log "Solr file found. Uploading..."
        if ! sudo -u solr bash -c "curl http://localhost:8080/api/admin/index/solr/schema | bash $SOLR_FIELD_UPDATER_FILE $SOLR_SCHEMA_PATH" ; then
            log "Error updating with the Solr fields from update-fields script."
            return 1
        fi
        log "Update completed successfully."
        sudo rm -f $SOLR_FIELD_UPDATER_FILE
    else
        log "Solr file is missing at $SOLR_FIELD_UPDATER_FILE."
        return 1
    fi

    # New field that caused problems: Software Description "license" field.
    # This is a dropdown controlled vocab list.
    # Add this line to the schema.xml file.
    # <field name="license" type="keyword" indexed="true" stored="true" multiValued="false" />
    # Warning: Custom fieldNames weren't copied over
    log "Warning: Custom fieldNames weren't copied over"
    log " - - - - - - - - -"
    log "Please copy over custom fields from the previous schema.xml file manually."
    log " - - - - - - - - -"
    log "Adding license field to schema.xml"
    if ! grep -q '<field name="license"' $SOLR_SCHEMA_PATH; then
        sudo sed -i '/<!-- SCHEMA-FIELDS::END -->/a     <field name="license" type="string" indexed="true" stored="true" multiValued="false" />' $SOLR_SCHEMA_PATH
    fi

    status_solr=$(curl "http://localhost:8983/solr/admin/cores?action=STATUS")
    log "$status_solr"
    log "To test the new schema.xml file, run the following command:"
    log "curl \"http://localhost:8983/solr/admin/cores?action=STATUS\""
    log "If you see any errors, please check the schema.xml file for any issues."
    log "If you see no errors, then the new schema.xml file is working."
}

deploy_new_version() {
    if ! sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin list-applications | grep -q "dataverse-$TARGET_VERSION"; then
        log "Deploying new Dataverse version..."
        sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin deploy "$DATAVERSE_WAR_FILE" || return 1
    else
        log "Dataverse version $TARGET_VERSION is already deployed. Skipping deployment."
    fi
}

export_all_metadata() {
    sudo -u $DATAVERSE_USER curl http://localhost:8080/api/admin/metadata/reExportAll || return 1
}

status_solr() {
    while true; do
        result=$(sudo -u $SOLR_USER bash -c "curl -s http://localhost:8983/solr/admin/cores?action=STATUS")

        # Check for initFailures
        init_failure=$(echo "$result" | jq -r '.initFailures.collection1 // empty')
        if [[ -n "$init_failure" ]]; then
            log "Error: Solr initialization failure detected:"
            log "$init_failure"
            return 1
        fi

        # Extract current, numDocs, and maxDoc values
        current=$(echo "$result" | jq '.status.collection1.index.current')
        numDocs=$(echo "$result" | jq '.status.collection1.index.numDocs')
        maxDoc=$(echo "$result" | jq '.status.collection1.index.maxDoc')

        # Display progress on the same line
        printf "\rIndexing progress: numDocs=%s, maxDoc=%s" "$numDocs" "$maxDoc"

        # Check if indexing is current
        if [[ "$current" == "true" ]]; then
            log "Indexing complete."
            break
        fi
        sleep 1
    done
}

# Waiting for payara to come back up.
wait_for_site() {
    local url="https://${DOMAIN}/dataverse/root?q="
    local response_code

    log "Waiting for site to become available..."
        
    while true; do
        # Get HTTP response code
        response_code=$(curl -o /dev/null -s -w "%{http_code}" "$url")

        if [[ "$response_code" -eq 200 ]]; then
            log "Site is up (HTTP 200 OK)."
            break
        else
            printf "\r - Waiting... (HTTP response: %s)" "$response_code"
        fi

        # Wait 1 seconds before checking again
        sleep 1
    done
}

reindex_solr() {
    # Call Solr for status
    status_solr
    sudo -u $DATAVERSE_USER curl -X DELETE http://localhost:8080/api/admin/index/timestamps || return 1
    sudo -u $DATAVERSE_USER curl http://localhost:8080/api/admin/index/continue || return 1
    sudo -u $DATAVERSE_USER curl http://localhost:8080/api/admin/index/status || return 1
    log "Waiting for solr to complete it's reindex"
    status_solr
}

set_rate_limit() {
    # Define the JSON file and the API endpoint
    API_ENDPOINT="http://localhost:8080/api/admin/settings/:RateLimitingCapacityByTierAndAction"

    # Ensure the JSON file exists
    if [[ ! -f "$RATE_LIMIT_JSON_FILE" ]]; then
        log "No JSON file $RATE_LIMIT_JSON_FILE not found."
        log "For more info: https://guides.dataverse.org/en/6.2/installation/config.html#rate-limiting"
    else
        # Use curl to send the contents of the JSON file with a PUT request
        sudo -u $DATAVERSE_USER curl "$API_ENDPOINT" -X PUT -d @"$RATE_LIMIT_JSON_FILE" -H "Content-Type: application/json" | jq || return 1
        log "Request sent using JSON file: $RATE_LIMIT_JSON_FILE"
    fi
}

update_set_permalink() {
    # Switch type from FAKE to datacite
    # https://guides.dataverse.org/en/6.2/installation/config.html#dataverse-pid-type
    local commands=(
        '-Ddataverse.pid.perma1.type=FAKE'
        '-Ddataverse.pid.perma1.label=PermaLink'
        '-Ddataverse.pid.perma1.authority=10.7281'
        '-Ddataverse.pid.perma1.shoulder=T1'
        '-Ddataverse.pid.perma1.permalink.base-url=https\://dataverse-clone.mse.jhu.edu'
        '-Ddataverse.pid.perma1.permalink.separator=\/'
        '-Ddataverse.pid.perma1.permalink.identifier-generation-style=randomString'
        '-Ddataverse.pid.default-provider=perma1'
        '-Ddataverse.pid.providers=perma1'
    )

    local cmd
    if ! sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin list-jvm-options | grep -F "Ddataverse.pid.providers=perma1"; then
        for cmd in "${commands[@]}"; do
                if ! sudo -u $DATAVERSE_USER $PAYARA/bin/asadmin create-jvm-options "$cmd"; then
                    log "Error: Command failed -> $cmd"
                    return 1
                fi
        done
        log "All commands executed successfully."
    else
        log "Permalinks already set, nothing to do."
    fi
}

replace_doi_with_DOI() {
    local file="${PAYARA}/glassfish/domains/domain1/applications/dataverse-6.2/dataset.xhtml"
    # Likely on line 595

    # Ensure the file exists
    if [[ ! -f "$file" ]]; then
        log "Error: File $file not found."
        return 1
    fi

    # Use pattern matching to find and replace only the specific instance
    # This looks for a line containing "datasetVersionUI.citation.data" and replaces only on that line
    sudo sed -i '/datasetVersionUI\.citation\.data/ s/DatasetPage\.doi/DatasetPage\.DOI/' "$file"

    # Verify if the replacement was successful
    if ! grep -q 'DatasetPage\.DOI' "$file"; then
        log "Error: Replacement failed."
        return 1
    fi

    log "Replacement successful in file: $file"
}

main() {
    log "Pre-req: ensure Payara environment variables are set"
    export PAYARA="$PAYARA"
    
    # Check for required commands
    log "Checking for required system commands..."
    check_required_commands
    
    log "Checking $BASHRC_FILE for payara export"
    sleep 2
    if ! sudo -u $DATAVERSE_USER grep -qF "$PAYARA_EXPORT_LINE" "$BASHRC_FILE"; then
        log " - Line not found in .bashrc. Adding it..."
        sudo -u $DATAVERSE_USER bash -c "echo -e '\n$PAYARA_EXPORT_LINE' >> $BASHRC_FILE"
        log " - Line added to .bashrc."
    else
        log " - Line already exists in .bashrc. Skipping addition."
    fi

    log "Check if Dataverse is running the correct version"
    sleep 2
    if ! check_current_version; then
        log " - Failed to find $CURRENT_VERSION deployed."
        exit 1
    fi

    log "Step 1: Update Solr schema.xml"
    log "Stopping Solr."
    if ! stop_solr; then
        log " - Step 1: Error stopping Solr."
        exit 1
    fi

    sleep 2
    log "Downloading the Solr schema files"
    if ! download_solr_schema_file; then
        log " - Step 1: Failed to download Solr's schema. Exiting script."
        exit 1
    fi
    log "Updating the Solr schema files"
    if ! update_solr_schema_file; then
        log " - Step 1: Failed to copy Solr's schema to solr. Exiting script."
        exit 1
    fi

    sleep 2
    log "Starting Solr."
    if ! start_solr; then
        log " - Step 1: Error starting Solr."
        exit 1
    fi

    log "Step 2: Undeploy the existing version"
    sleep 2
    if ! undeploy_dataverse; then
        log " - Step 2: Error during undeploy."
        exit 1
    fi

    log "Step 3: Stop Payara and clean directories"
    sleep 2
    if ! stop_payara || ! clean_generated_dir; then
        log " - Step 3: Error stopping Payara or cleaning generated directories."
        exit 1
    fi

    log "Step 4: Start Payara and deploy the new version"
    sleep 2
    if ! start_payara; then
        log " - Step 4: Error starting Payara."
        exit 1
    fi

    log "Step 5: Download WAR file."
    sleep 2
    if ! download_war_file; then
        log " - Step 5: Failed to download WAR file. Exiting script."
        exit 1
    fi
    log "Step 5: Deploying WAR file."
    if ! deploy_new_version; then
        log " - Step 5: Error deploying new version."
        exit 1
    fi

    log "Wait for Payara to come up."
    wait_for_site

    log "Step 6:For installations with internationalization: Please remember to update translations via Dataverse language packs."
    log " - Step 6: Skipped"
    # File are automatically pulled into ${PAYARA}/glassfish/domains/domain1/applications/dataverse-6.2/WEB-INF/classes/propertyFiles/
    
    log "Step 7: Restart Payara"
    sleep 2
    if ! stop_payara || ! start_payara; then
        log " - Step 7: Error restarting Payara after deployment."
        exit 1
    fi

    log "Wait for Payara to come up."
    wait_for_site

    log "Step 8: Update the following Metadata Blocks to reflect the incremental improvements made to the handling of core metadata fields:"
    log "Step 8: Update Geospatial Metadata Block"
    sleep 2
    if ! download_geospatial_file; then
        log " - Step 8: Failed to download geospatial file. Exiting script."
        exit 1
    fi
    if ! update_geospatial_metadata_block; then
        log " - Step 8: Failed to update geospatial metadata block. Exiting script."
        exit 1
    fi

    log "Step 8: Update Citation Metadata Block"
    sleep 2
    if ! download_citation_file; then
        log " - Step 8: Failed to download citation file. Exiting script."
        exit 1
    fi
    if ! update_citation_metadata_block; then
        log " - Step 8: Failed to update citation metadata block. Exiting script."
        exit 1
    fi

    log "Step 8: Update atrophysics Metadata Block"
    sleep 2
    if ! download_astrophysics_file; then
        log " - Step 8: Failed to download atrophysics file. Exiting script."
        exit 1
    fi
    if ! update_astrophysics_metadata_block; then
        log " - Step 8: Failed to update atrophysics metadata block. Exiting script."
        exit 1
    fi

    log "Step 8: Update biomedical Metadata Block"
    sleep 2
    if ! download_biomedical_file; then
        log " - Step 8: Failed to download biomedical file. Exiting script."
        exit 1
    fi
    if ! update_biomedical_metadata_block; then
        log " - Step 8: Failed to update biomedical metadata block. Exiting script."
        exit 1
    fi

    log "Step 8: Run ReExportAll to update dataset metadata exports."
    sleep 2
    if ! export_all_metadata; then
        log " - Step 8: Error exporting all metadata."
        exit 1
    fi

    log "Step 9: For installations with custom or experimental metadata blocks:"
    if ! stop_solr; then
        log " - Step 9: Error stopping Solr."
        exit 1
    fi

    sleep 2
    if ! download_solr_schema_updater; then
        log " - Step 9: Failed to download Solr's schema. Exiting script."
        exit 1
    fi
    if ! update_solr_schema_updater; then
        log " - Step 9: Failed to update Solr schema. Exiting script."
        exit 1
    fi

    sleep 2
    log "Starting Solr."
    if ! start_solr; then
        log " - Step 9: Error starting Solr."
        exit 1
    fi

    log "Step 9: Run Solr's reindex."
    if ! reindex_solr; then
        log " - Step 8: Error reindexing solr."
        exit 1
    fi
    
    log "Additional Step: set rate limits."
    if ! set_rate_limit; then
        log " - Additional Step: Error setting rate limits."
        exit 1
    fi
    
    log "Additional Step: set permalink."
    if ! update_set_permalink; then
        log " - Additional Step: Error setting permlink configs."
        exit 1
    fi

    log "Additional Step: Fix when MDC is displayed"
    sleep 2
    # Check to see if MDC is displayed
    if check_mdc_displayed; then
        if ! replace_doi_with_DOI; then
            log " - Additional Step: Error Fix when MDC is displayed #10463."
            log " - IQSS/10462 - https://github.com/IQSS/dataverse/issues/10907"
            exit 1
        fi
        log " - MDC is displayed, nothing to do."
    else
        log " - MDC is not displayed, nothing to do."
    fi

    log "Additional Step: Restart Payara"
    sleep 2
    if ! stop_payara || ! start_payara; then
        log " - Step 7: Error restarting Payara after deployment."
        exit 1
    fi

    sleep 2
    log "\n\nUpgrade to Dataverse $TARGET_VERSION completed successfully.\n\n"
}

# Run the main function
main "$@"
