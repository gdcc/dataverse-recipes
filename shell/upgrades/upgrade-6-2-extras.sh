#!/bin/bash

# Globals
DOMAIN=".mse.jhu.edu"
PAYARA="/usr/local/payara"
CURRENT_VERSION="6.2"
DATAVERSE_USER="dataverse"
PAYARA_EXPORT_LINE="export PAYARA=\"$PAYARA\""
BAGIT_NUMBER_OF_THREADS=10

BAGIT_SITE_NAME="Johns Hopkins Research Data Repository, RRID:SCR_014728"
BAGIT_FULL_ADDRESS="Johns Hopkins University, 3400 N. Charles St., Baltimore, MD 21218-2683"
BAGIT_EMAIL="dataservices@jhu.edu"

CROISSANT_METADATA_EXPORTER_URL="https://repo1.maven.org/maven2/io/gdcc/export/croissant/0.1.2/croissant-0.1.2.jar"
CROISSANT_JAR_FILE=$(basename "$CROISSANT_METADATA_EXPORTER_URL")
CROISSANT_METADATA_EXPORTER_SHA1="20e27873e4a255f7f07c7e5bc9a7b06bf098a39b"
METADATA_JAR_FILE_DIRECTORY="/mnt/dvn/dv-content/exporters"

# Ensure the script is not run as root
if [[ $EUID -eq 0 ]]; then
    printf "Please do not run this script as root.\n" >&2
    printf "This script runs several commands with sudo from within functions.\n" >&2
    exit 1
fi

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

check_current_version() {
    local version response
    response=$(sudo -u dataverse $PAYARA/bin/asadmin list-applications)

    # Check if "No applications are deployed to this target server" is part of the response
    if [[ "$response" == *"No applications are deployed to this target server"* ]]; then
        printf " - No applications are deployed to this target server. Assuming upgrade is needed.\n"
        return 0
    fi

    # If no such message, check the Dataverse version via the API
    version=$(curl -s "http://localhost:8080/api/info/version" | grep -oP '\d+\.\d+')

    # Check if the version matches the expected current version
    if [[ $version == "$CURRENT_VERSION" ]]; then
        return 0
    else
        printf " - Current Dataverse version is not %s. Upgrade cannot proceed.\n" "$CURRENT_VERSION" >&2
        return 1
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

stop_solr() {
    if pgrep -f solr > /dev/null; then
        printf " - Stopping Solr service...\n"
        sudo systemctl stop solr || return 1
    else
        printf " - Solr is already stopped.\n"
    fi
}

start_solr() {
    if ! pgrep -f solr > /dev/null; then
        printf " - Starting Solr service...\n"
        sudo systemctl start solr || return 1
    else
        printf " - Solr is already running.\n"
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

# Function to Configuring bag-info.txt
# https://guides.dataverse.org/en/latest/installation/config.html#configuring-bag-info-txt
set_jvm_option() {
    local option_key=$1
    local option_value=$2

    # Prepare the full JVM option string
    local jvm_option="-D${option_key}=${option_value}"

    # Check if the JVM option already exists
    local current_options=$(sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" list-jvm-options)
    
    if [[ "$current_options" == *"$jvm_option"* ]]; then
        echo " - JVM option $jvm_option is already set correctly."
    else
        echo " - Setting JVM option $jvm_option..."
        if ! sudo -u "$DATAVERSE_USER" "$PAYARA/bin/asadmin" create-jvm-options "$jvm_option"; then
            echo " - Error setting JVM option $jvm_option." >&2
            return 1
        fi
    fi
}

set_bagit_info_txt() {
    echo " - Setting the Bagit global values for name, address, email, and number of threads."

    # Set the JVM options for name, address, and email
    set_jvm_option "dataverse.bagit.sourceorg.name" "$BAGIT_SITE_NAME" || return 1
    set_jvm_option "dataverse.bagit.sourceorg.address" "$BAGIT_FULL_ADDRESS" || return 1
    set_jvm_option "dataverse.bagit.sourceorg.email" "$BAGIT_EMAIL" || return 1

    # Check and set the number of threads for BagGenerator
    current_thread_size=$(curl -s http://localhost:8080/api/admin/settings/:BagGeneratorThreads)
    if [ -z "$current_thread_size" ] || [ "$current_thread_size" != "$BAGIT_NUMBER_OF_THREADS" ]; then
        echo " - Number of threads setting not found or incorrect, updating to $BAGIT_NUMBER_OF_THREADS..."
        if ! sudo -u "$DATAVERSE_USER" curl -X PUT -d "$BAGIT_NUMBER_OF_THREADS" http://localhost:8080/api/admin/settings/:BagGeneratorThreads; then
            echo " - Error setting Bagit value for BagGeneratorThreads to $BAGIT_NUMBER_OF_THREADS." >&2
            return 1
        fi
    else
        echo " - Number of threads is already set correctly to $BAGIT_NUMBER_OF_THREADS."
    fi

    # Check and set the number of threads for BagValidatorJobPoolSize
    current_validate_pool_size=$(curl -s http://localhost:8080/api/admin/settings/:BagValidatorJobPoolSize)
    if [ -z "$current_validate_pool_size" ] || [ "$current_validate_pool_size" != "$BAGIT_NUMBER_OF_THREADS" ]; then
        echo " - Number of threads for validation not found or incorrect, updating to $BAGIT_NUMBER_OF_THREADS..."
        if ! sudo -u "$DATAVERSE_USER" curl -X PUT -d "$BAGIT_NUMBER_OF_THREADS" http://localhost:8080/api/admin/settings/:BagValidatorJobPoolSize; then
            echo " - Error setting Bagit value for BagValidatorJobPoolSize to $BAGIT_NUMBER_OF_THREADS." >&2
            return 1
        fi
    else
        echo " - Number of validation threads is already set correctly to $BAGIT_NUMBER_OF_THREADS."
    fi

    echo " - Successfully set values."
}

enable_guestbook() {
    echo " - Setting the JVM options to allow guestbooks to be displayed when a user requests access.."
    # https://guides.dataverse.org/en/6.1/installation/config.html#dataverse-files-guestbook-at-request

    set_jvm_option "dataverse.files.guestbook-at-request" "TRUE" || return 1
    echo " - Enabled."

    # To modify this behavior either by a global default, collection-level settings, or directly at the dataset level.
    # https://guides.dataverse.org/en/6.1/api/native-api.html#configure-when-a-dataset-guestbook-appears-if-enabled
}

enable_croissant() {
    echo " - Setting the JVM options to enable Croissant metadata exporter."

    sudo mkdir -p $METADATA_JAR_FILE_DIRECTORY
    sudo chown dataverse:dataverse $METADATA_JAR_FILE_DIRECTORY

    # Check if file exists and matches the expected hash
    if ! check_file_hash "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}" "$CROISSANT_METADATA_EXPORTER_SHA1"; then
        # If the file doesn't exist or the hash doesn't match, download it
        download_file "$CROISSANT_METADATA_EXPORTER_URL" "${CROISSANT_JAR_FILE}"
        sudo mv "${CROISSANT_JAR_FILE}" "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}"

        # Check the hash again after downloading
        if check_file_hash "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}" "$CROISSANT_METADATA_EXPORTER_SHA1"; then
            echo " - Downloaded file hash matches the expected hash."
        else
            echo " - Downloaded file hash does not match the expected hash. Aborting."
            rm -f "${METADATA_JAR_FILE_DIRECTORY}/${CROISSANT_JAR_FILE}"
            exit 1
        fi
    fi
    sudo chown -R dataverse:dataverse $METADATA_JAR_FILE_DIRECTORY

    set_jvm_option "dataverse.exporter.metadata.croissant.enabled" "TRUE" || return 1
    set_jvm_option "dataverse.spi.exporters.directory" "$METADATA_JAR_FILE_DIRECTORY" || return 1

    echo " - Enabled."
}

enable_binder_tool() {
    echo " - Setting the JVM options to enable binder tool."
    # Fetch the list of toolNames
    tool_names=$(curl -s http://localhost:8080/api/admin/externalTools | jq -r '.data[].toolName')

    # Check if "benderExplore" is in the list
    if echo "$tool_names" | grep -q "benderExplore"; then
        echo " - The Bender tool is in the list."
    else
        echo " - The Bender tool is NOT in the list."
        curl -X POST -H 'Content-type: application/json' http://localhost:8080/api/admin/externalTools -d \
        '{
        "displayName": "Binder",
        "toolName": "benderExplore",
        "description": "Run on Binder",
        "scope": "dataset",
        "type": "explore",
        "toolUrl": "https://iqss.github.io/dataverse-binder-redirect/v1/",
        "toolParameters": {
            "queryParameters": [
            {
                "datasetPid": "{datasetPid}"
            }
            ]
        }
        }' || return 1
    fi    
    echo " - Enabled."
}

enable_whole_tale() {
    echo " - Enable the tools to Analyze in Whole Tale."
    # Fetch the list of toolNames
    tool_names=$(curl -s http://localhost:8080/api/admin/externalTools | jq -r '.data[].toolName')

    # Check if "wholeTaleExplore" is in the list
    if echo "$tool_names" | grep -q "wholeTaleExplore"; then
        echo " - The Whole Tale is in the list."
    else
        echo " - The Whole Tale is NOT in the list."
        curl -X POST -H 'Content-type: application/json' http://localhost:8080/api/admin/externalTools -d \
        '{
            "displayName": "Whole Tale",
            "toolName": "wholeTaleExplore",
            "description": "Analyze in Whole Tale",
            "scope": "dataset",
            "type": "explore",
            "toolUrl": "https://data.wholetale.org/api/v1/integration/dataverse",
            "toolParameters": {
                "queryParameters": [
                {
                    "datasetPid": "{datasetPid}"
                },
                {
                    "siteUrl": "{siteUrl}"
                },
                {
                    "key": "{apiToken}"
                }
            ]
        }
        }' || return 1
    fi    
    echo " - Enabled."
}

enable_markdown_previewer() {
    # Check if /home/$DATAVERSE_USER/dataverse-previewers doesn't exist, clone it
    if [[ ! -d "dataverse-previewers" ]]; then
        git clone https://github.com/gdcc/dataverse-previewers || { printf "Error cloning dataverse-previewers repository\n" >&2; return 1; }
    fi

    if [[ ! -d "/home/$DATAVERSE_USER/dataverse-previewers" ]]; then
        # Set permissions for the dataverse-previewers directory
        sudo chmod -R +x dataverse-previewers/localinstall.sh
        sudo chown -R "$DATAVERSE_USER:" dataverse-previewers
        sudo chmod -R 775 dataverse-previewers
        sudo mv dataverse-previewers /home/$DATAVERSE_USER/dataverse-previewers || { printf "Error moving dataverse-previewers to the correct directory\n" >&2; return 1; }
    fi

    # Fetch the list of external tools from Dataverse
    local list_of_tools
    if ! list_of_tools=$(curl -s http://localhost:8080/api/admin/externalTools | jq -r '.data[].toolName'); then
        printf "Error retrieving external tools from Dataverse\n" >&2
        return 1
    fi

    # If mdPreviewer is not in the $list_of_tools, install it
    if ! grep -q "mdPreviewer" <<< "$list_of_tools"; then
        sudo -u "$DATAVERSE_USER" bash -c "cd /home/$DATAVERSE_USER/dataverse-previewers && ./localinstall.sh previewers/v1.4 https://archive.data.jhu.edu/previewers" || {
            printf "Error running the localinstall.sh script\n" >&2
            return 1
        }
    else
        printf "mdPreviewer is already installed\n"
        return 0
    fi

    # Request the API key from the user
    local api_key
    read -p "Enter your API key: " api_key

    # Register the mdPreviewer external tool in Dataverse
    # https://github.com/gdcc/dataverse-previewers/blob/develop/6.1curlcommands.md
    curl -s -H "X-Dataverse-key: $api_key" -X POST -H 'Content-type: application/json' \
    http://localhost:8080/api/admin/externalTools -d \
    '{
        "displayName":"Show Markdown (MD)",
        "description":"View the Markdown file.",
        "toolName":"mdPreviewer",
        "scope":"file",
        "types":["preview"],
        "toolUrl":"https://gdcc.github.io/dataverse-previewers/previewers/v1.4/MdPreview.html",
        "toolParameters": {
            "queryParameters":[
                {"fileid":"{fileId}"},
                {"siteUrl":"{siteUrl}"},
                {"datasetid":"{datasetId}"},
                {"datasetversion":"{datasetVersion}"},
                {"locale":"{localeCode}"}
            ]
        },
        "contentType":"text/markdown",
        "allowedApiCalls": [
            {
            "name": "retrieveFileContents",
            "httpMethod": "GET",
            "urlTemplate": "/api/v1/access/datafile/{fileId}?gbrecs=true",
            "timeOut": 3600
            },
            {
            "name": "downloadFile",
            "httpMethod": "GET",
            "urlTemplate": "/api/v1/access/datafile/{fileId}?gbrecs=false",
            "timeOut": 3600
            },
            {
            "name": "getDatasetVersionMetadata",
            "httpMethod": "GET",
            "urlTemplate": "/api/v1/datasets/{datasetId}/versions/{datasetVersion}",
            "timeOut": 3600
            }
        ]
    }' || { printf "Error registering the mdPreviewer tool\n" >&2; return 1; }

    printf "Markdown previewer successfully enabled\n"
}



main() {
    echo -e "\nWait for Payara to come up."
    wait_for_site

    echo "Pre-req: ensure Payara environment variables are set"
    export PAYARA="$PAYARA"
    echo -e "\nCheck if Dataverse is running the correct version"
    sleep 2
    if ! check_current_version; then
        printf " - Failed to find $CURRENT_VERSION deployed.\n\n" >&2
        exit 1
    else
        printf " - Found Payara v.${CURRENT_VERSION} running.\n\n" >&2
    fi

    echo -e "Extra Step: Set values for bag-info-txt"
    # https://guides.dataverse.org/en/latest/installation/config.html#configuring-bag-info-txt
    if ! set_bagit_info_txt; then
        printf " - Step : Error setting bagit_info.txt values.\n\n" >&2
        exit 1
    fi

    echo -e "\n\nExtra Step: Enable Guestbook"
    sleep 2
    if ! enable_guestbook; then
        printf " - Step 7: Error could not Enable Guestbook.\n\n" >&2
        exit 1
    fi

    echo -e "\n\nExtra Step: Enable Croissant metadata exporter"
    sleep 2
    if ! enable_croissant; then
        printf " - Step 7: Error could not Enable Croissant metadata exporter.\n\n" >&2
        exit 1
    fi

    echo -e "\n\nExtra Step: Enable Binder tool"
    # https://github.com/IQSS/dataverse-binder-redirect
    sleep 2
    if ! enable_binder_tool; then
        printf " - Step 7: Error could not Enable Binder tool.\n\n" >&2
        exit 1
    fi

    echo -e "\n\nExtra Step: Enable Whole Tale"
    # https://wholetale.readthedocs.io/en/stable/users_guide/integration.html
    sleep 2
    if ! enable_whole_tale; then
        printf " - Step 7: Error could not Enable Whole Tale.\n\n" >&2
        exit 1
    fi

    # Final steps
    echo -e "\n\nExtra Step: Restart Payara"
    sleep 2
    if ! stop_payara || ! start_payara; then
        printf " - Step 7: Error restarting Payara after deployment.\n" >&2
        exit 1
    fi

    echo -e "\nWait for Payara to come up."
    wait_for_site

    printf "\n\nWaiting for Dataverse to restart."
    start=$(date +%s); while ! curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/admin/externalTools | grep -q 200; do sleep 1; done; end=$(date +%s); echo " - Service came up after $((end - start)) seconds."

    echo -e "\nEnable Markdown previewer."
    # https://github.com/gdcc/dataverse-previewers
    if ! enable_markdown_previewer; then
        printf " - Step 8: Error could not Enable Markdown Previewer.\n\n" >&2
        exit 1
    fi

    printf "\n\n Extras set and Enabled to Dataverse %s completed successfully.\n\n" "$CURRENT_VERSION"
    printf "\n\nDataverse restart complete."
}

main "$@"
