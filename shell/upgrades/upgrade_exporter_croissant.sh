#!/bin/bash

# This script is used to upgrade the croissant exporter to the latest version.

# Load environment variables from .env file
if [[ -f ".env" ]]; then
    source ".env"
else
    echo "Error: .env file not found. Please create one based on sample.env"
    exit 1
fi

# Required variables check
if [[ -z "$DOMAIN" || -z "$PAYARA" || -z "$DATAVERSE_USER" || -z "$CROISSANT_VERSION" || -z "$METADATA_JAR_FILE_DIRECTORY" ]]; then
    echo "Error: Required environment variables are not set in .env file."
    echo "Please ensure DOMAIN, PAYARA, DATAVERSE_USER, CROISSANT_VERSION, and METADATA_JAR_FILE_DIRECTORY are defined."
    exit 1
fi

# Globals
CROISSANT_METADATA_EXPORTER_URL="https://repo1.maven.org/maven2/io/gdcc/export/croissant/${CROISSANT_VERSION}/croissant-${CROISSANT_VERSION}.jar"
CROISSANT_JAR_FILE=$(basename "$CROISSANT_METADATA_EXPORTER_URL")
CROISSANT_METADATA_EXPORTER_SHA1=""
CROISSANT_METADATA_EXPORTER_SHA1_URL="https://repo1.maven.org/maven2/io/gdcc/export/croissant/${CROISSANT_VERSION}/croissant-${CROISSANT_VERSION}.jar.sha1"

# Ensure the script is not run as root
if [[ $EUID -eq 0 ]]; then
    printf "Please do not run this script as root.\n" >&2
    printf "This script runs several commands with sudo from within functions.\n" >&2
    exit 1
fi

fetch_croissant_hash() {
    local url="$1"
    CROISSANT_METADATA_EXPORTER_SHA1=$(curl -s "$url")
}

# Function to check the file hash
check_file_hash() {
    local file="$1"
    local expected_hash="$2"
    
    if [[ -f "$file" ]]; then
        actual_hash=$(sha1sum "$file" | awk '{print $1}')
        if [[ "$actual_hash" == "$expected_hash" ]]; then
            echo " - File exists and hash matches."
            return 0
        else
            echo " - File exists but hash does not match."
            return 1
        fi
    else
        echo " - File does not exist."
        return 1
    fi
}

# Function to download the file
download_file() {
    local url="$1"
    local destination="$2"
    
    echo " - Downloading $url..."
    curl -L -o "$destination" "$url"
    
    if [[ $? -eq 0 ]]; then
        echo " - Download completed."
    else
        echo " - Download failed."
        exit 1
    fi
}

# Function to stop Payara service
stop_payara() {
    if pgrep -f payara > /dev/null; then
        printf " - Stopping Payara service...\n"
        sudo systemctl stop payara || return 1
    else
        printf " - Payara is already stopped.\n"
    fi
}


# Function to start Payara service
start_payara() {
    if ! pgrep -f payara > /dev/null; then
        printf " - Starting Payara service...\n"
        sudo systemctl start payara || return 1
    else
        printf " - Payara is already running.\n"
    fi
}

# Waiting for payara to come back up.
wait_for_site() {
    local url="https://${DOMAIN}/dataverse/root?q="
    local response_code

    printf " - Waiting for site to become available...\n"
    
    while true; do
        # Get HTTP response code
        response_code=$(curl -o /dev/null -s -w "%{http_code}" "$url")

        if [[ "$response_code" -eq 200 ]]; then
            printf " - Site is up (HTTP 200 OK).\n"
            break
        else
            printf "\r - Waiting... (HTTP response: %s)" "$response_code"
        fi

        # Wait 1 seconds before checking again
        sleep 1
    done
}

set_jvm_option() {
    local option_key=$1
    local option_value=$2

    # Prepare the full JVM option string
    local jvm_option="-D${option_key}=${option_value}"

    # Check if the JVM option already exists
    local current_options
    if ! current_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options 2>/dev/null); then
        echo " - Error listing JVM options. Please check if Payara is running and accessible." >&2
        return 1
    fi
    
    if [[ "$current_options" == *"$jvm_option"* ]]; then
        echo " - JVM option $jvm_option is already set correctly."
    else
        echo " - Setting JVM option $jvm_option..."
        if ! sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$jvm_option" 2>/dev/null; then
            echo " - Error setting JVM option $jvm_option. Please check if Payara is running and accessible." >&2
            return 1
        fi
    fi
}

disable_croissant() {
    echo " - Disabling Croissant metadata exporter..."
    set_jvm_option "dataverse.exporter.metadata.croissant.enabled" "FALSE" || return 1
    echo " - Disabled."
}

enable_croissant() {
    echo " - Setting the JVM options to enable Croissant metadata exporter."

    sudo mkdir -p $METADATA_JAR_FILE_DIRECTORY
    # Get the owner and group of the directory to match the permissions of the existing files
    local directory_owner=$(stat -c "%U" $METADATA_JAR_FILE_DIRECTORY)
    local directory_group=$(stat -c "%G" $METADATA_JAR_FILE_DIRECTORY)

    # Remove old Croissant jar files if they exist
    echo " - Removing old Croissant jar files..."
    sudo rm -f $METADATA_JAR_FILE_DIRECTORY/croissant-*.jar

    # Check if file exists and matches the expected hash
    if ! check_file_hash "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}" "$CROISSANT_METADATA_EXPORTER_SHA1"; then
        # If the file doesn't exist or the hash doesn't match, download it
        download_file "$CROISSANT_METADATA_EXPORTER_URL" "${CROISSANT_JAR_FILE}"
        sudo install -o $directory_owner -g $directory_group "${CROISSANT_JAR_FILE}" "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}"

        # Check the hash again after downloading
        if check_file_hash "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}" "$CROISSANT_METADATA_EXPORTER_SHA1"; then
            echo " - Downloaded file hash matches the expected hash."
        else
            echo " - Downloaded file hash does not match the expected hash. Aborting."
            rm -f "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}"
            exit 1
        fi
    fi

    set_jvm_option "dataverse.exporter.metadata.croissant.enabled" "TRUE" || return 1
    set_jvm_option "dataverse.spi.exporters.directory" "$METADATA_JAR_FILE_DIRECTORY" || return 1

    echo " - Enabled."
}

re_export_metadata() {
    echo " - Re-exporting all metadata formats..."
    curl http://localhost:8080/api/admin/metadata/reExportAll || return 1
    echo " - Re-export completed."
}

main() {
    echo -e "\nWait for Payara/Dataverse to come up."
    wait_for_site

    echo "Pre-req: ensure Payara environment variables are set"
    export PAYARA="$PAYARA"

    echo -e "\nStep 1: Disable Croissant"
    sleep 2
    if ! disable_croissant; then
        printf " - Error disabling Croissant.\n\n" >&2
        exit 1
    fi

    echo -e "\nStep 3: Install new Croissant version"
    sleep 2

    echo "Fetching the hash of the croissant metadata exporter"
    if ! fetch_croissant_hash "$CROISSANT_METADATA_EXPORTER_SHA1_URL"; then
        printf " - Error fetching the hash of the croissant metadata exporter.\n\n" >&2
        exit 1
    fi

    echo " - Hash fetched successfully."

    echo "Installing new Croissant version"
    if ! enable_croissant; then
        printf " - Error installing new Croissant version.\n\n" >&2
        exit 1
    fi

    echo -e "\nWait for Payara to come up."
    wait_for_site

    echo -e "\nStep 5: Re-export all metadata"
    sleep 2
    if ! re_export_metadata; then
        printf " - Error re-exporting metadata.\n\n" >&2
        exit 1
    fi

    printf "\n\nCroissant reinstallation complete."
}

main "$@"
