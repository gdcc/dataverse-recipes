#!/bin/bash

# Function to check if a command is available
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
required_commands=("wget" "grep" "sed")
missing_commands=()

for cmd in "${required_commands[@]}"; do
    if ! command_exists "$cmd"; then
        missing_commands+=("$cmd")
    fi
done

if [ ${#missing_commands[@]} -ne 0 ]; then
    echo "Error: The following required commands are not available:"
    for cmd in "${missing_commands[@]}"; do
        echo "  - $cmd"
    done
    echo "Please install these commands and try again."
    exit 1
fi

print_usage() {
    echo "Download the files from a Dataverse dataset"
    echo "Usage: $0 <server> <persistentId> [--wait=<wait_time>] [--apikey=<api_key>] [--version=<version>] [--ignoreForbidden]"
    echo "Example: $0 https://demo.dataverse.org doi:10.5072/F2ABCDEF --wait=0.75 --apikey=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --version=1.2 --ignoreForbidden"
    echo ""
    echo "Optional parameters:"
    echo "  --wait=<wait_time>: Time in seconds to wait between file downloads (can be a fraction)."
    echo "  --apikey=<api_key>: API key for accessing restricted or embargoed files"
    echo "  --version=<version>: Specific version to download (e.g., '1.2' or ':draft')"
    echo "  --ignoreForbidden: Continue downloading even if some files return a 403 Forbidden error"
}

# Check if the required parameters are provided
if [ $# -lt 2 ]; then
    print_usage
    exit 1
fi

dvserver="$1"
persistentId="$2"
wait_time=0
api_key=""
version=""
ignoreForbidden=false

# Parse optional parameters
shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait=*)
        wait_time="${1#*=}"
        shift
        ;;
        --apikey=*)
        api_key="${1#*=}"
        shift
        ;;
        --version=*)
        version="${1#*=}"
        shift
        ;;
        --ignoreForbidden)
        ignoreForbidden=true
        shift
        ;;
        *)
        echo "Unknown parameter: $1"
        print_usage
        exit 1
        ;;
    esac
done

# Escape forward slashes in persistentId with underscores
escaped_persistentId=$(echo "$persistentId" | tr '/' '_')

# If version is set, append it to escaped_persistentId
if [ -n "$version" ]; then
    escaped_persistentId="${escaped_persistentId}_${version}"
fi

# Function to URL decode a string
urldecode() {
    printf '%b' "${1//%/\\x}"
}

# Function to download a file
download_file() {
    local url="$1"
    local filename="$2"
    
    if [ -f "$filename" ] && grep -q "$filename" downloaded_files.txt; then
        echo "Skipping already downloaded file: $filename"
    else
        local wget_cmd="wget -c --wait=$wait_time"
        if [ -n "$api_key" ]; then
            wget_cmd+=" --header=\"X-Dataverse-key: $api_key\""
        fi
        if eval $wget_cmd \"$url\" -O \"$filename\"; then
            echo "$filename" >> downloaded_files.txt
            echo "Successfully downloaded: $filename"
        else
            local exit_code=$?
            if [ $exit_code -eq 8 ] && $ignoreForbidden; then
                echo "Warning: Failed to download (403 Forbidden): $filename"
                echo "Continuing due to --ignoreForbidden flag/assuming the file is restricted/embargoed/expired."
            else
                echo "Failed to download: $filename"
                echo "Exiting. If the problem is a temporary network error or rate limiting, you can try this script in a few minutes."
                echo "Do not delete the contents of the $escaped_persistentId directory and the script will continue where it left off."
                exit 1
            fi
        fi
    fi
}

# Change to the escaped_persistentId directory
mkdir -p "$escaped_persistentId"
cd "$escaped_persistentId" || exit 1

# Execute wget command to get the main directory index
if [ ! -f "dirindex" ]; then
    wget_cmd="wget --wait=$wait_time"
    if [ -n "$api_key" ]; then
        wget_cmd+=" --header=\"X-Dataverse-key: $api_key\""
    fi
    url="$dvserver/api/datasets/:persistentId/dirindex?persistentId=$persistentId"
    if [ -n "$version" ]; then
        url+="&version=$version"
    fi
    if ! eval $wget_cmd \"$url\" -O dirindex; then
        echo "Error: Failed to download the main directory index."
        echo "Exiting script due to download failure."
        exit 1
    fi
fi

# Create or load the list of downloaded files
touch downloaded_files.txt

# Function to process an index file
process_index() {
    local index_file="$1"
    local base_folder="$2"

    while IFS= read -r line; do
        if echo "$line" | grep -q 'href="/api/access/datafile/'; then
            # Process files (this part remains largely unchanged)
            local href=$(echo "$line" | sed -n 's/.*href="\([^"]*\)".*/\1/p')
            local name=$(echo "$line" | sed -n 's/.*>\(.*\)<\/a>.*/\1/p')
            local old_name=$(basename "$href")
            local new_name=$(echo "$name" | tr -cd '[:alnum:]._-')
            local folder="$base_folder"

            if [ -n "$folder" ]; then
                mkdir -p "$folder"
            fi

            download_file "$dvserver$href" "${folder:+$folder/}$new_name"

            if [ -f "${folder:+$folder/}$new_name" ]; then
                echo "Successfully downloaded: ${folder:+$folder/}$new_name"
            else
                echo "Warning: File '${folder:+$folder/}$new_name' not found."
            fi
        elif echo "$line" | grep -q 'href="/api/datasets/[0-9]*/dirindex/?.*folder='; then
            # Process subdirectories
            local subfolder=$(echo "$line" | sed -n 's/.*folder=\([^"]*\)".*/\1/p')
            subfolder=$(urldecode "$subfolder")
            local full_path="${base_folder:+$base_folder/}$subfolder"
            
            echo "Processing subdirectory: $full_path"
            
            # Download the subdirectory index
            local subindex_file="index_${subfolder//\//_}.html"
            download_file "$dvserver/api/datasets/:persistentId/dirindex?persistentId=$persistentId&folder=$subfolder" "$subindex_file"
            
            # Process the subdirectory
            process_index "$subindex_file" "$full_path"
            
            # Clean up the subdirectory index file
            rm "$subindex_file"
        fi
    done < "$index_file"
}

# Process the main dirindex file
process_index "dirindex" ""

# Clean up the main dirindex file
rm "dirindex"
rm "downloaded_files.txt"

echo "File organization complete."