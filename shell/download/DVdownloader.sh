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

# Check if the input file, persistentId, and optional wait time are provided
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Download the files from a Dataverse dataset"
    echo "Currently only works for the latest published dataset version and public (non-restricted, non-embargoed) files"
    echo "Usage: $0 <server> <persistentId> [wait_time]"
    echo "Example: $0 https://demo.dataverse.org doi:10.5072/F2ABCDEF 0.75"
    echo ""
    echo "Optional parameter:"
    echo "  wait_time: Time in seconds to wait between file downloads (can be a fraction)."
    echo "             For small files, a delay of 0.75 seconds would limit the script to"
    echo "             approximately 400 files per 5 minutes, which is the current rate limit"
    echo "             at https://dataverse.harvard.edu"
    exit 1
fi

dvserver="$1"
persistentId="$2"
wait_time=${3:-0}  # Default to 0 if not provided

# Escape forward slashes in persistentId with underscores
escaped_persistentId=$(echo "$persistentId" | tr '/' '_')

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
        if wget -c -nv --wait="$wait_time" "$url" -O "$filename"; then
            echo "$filename" >> downloaded_files.txt
            echo "Successfully downloaded: $filename"
        else
            echo "Failed to download: $filename"
        fi
    fi
}

# Change to the escaped_persistentId directory
mkdir -p "$escaped_persistentId"
cd "$escaped_persistentId" || exit 1

# Execute wget command to get the main directory index
if [ ! -f "dirindex" ]; then
    wget -nd -N -P "$escaped_persistentId" "$dvserver/api/datasets/:persistentId/dirindex?persistentId=$persistentId" -O dirindex -nv
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

            download_file "$dvserver$href" "${folder:+$folder/}$old_name"

            if [ -f "${folder:+$folder/}$old_name" ]; then
                mv "${folder:+$folder/}$old_name" "${folder:+$folder/}$new_name"
                echo "Renamed: ${folder:+$folder/}$old_name -> ${folder:+$folder/}$new_name"
            else
                echo "Warning: File '${folder:+$folder/}$old_name' not found."
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