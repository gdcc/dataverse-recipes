#!/bin/bash

# Check if the input file and persistentId are provided
if [ $# -ne 2 ]; then
    echo "Download the files from a Dataverse dataset"
    echo "Currently only works for the latest published dataset version and public (non-restricted, non-embargoed) files without a path/directoryLabel"

    echo "Usage: $0 <server> <persistentId>"
    echo "Example: $0 https://demo.harvard.edu doi:10.5072/F2ABCDEF"
    exit 1
fi

dvserver="$1"
persistentId="$2"

# Escape forward slashes in persistentId with underscores
escaped_persistentId=$(echo "$persistentId" | tr '/' '_')

# Function to URL decode a string
urldecode() {
    echo -e "${1//%/\\x}"
}

# Execute wget command
wget -nd -mpF -e robots=off -P "$escaped_persistentId" "$dvserver/api/datasets/:persistentId/dirindex?persistentId=$persistentId"


# Function to process a dirindex file
process_dirindex() {
    local dirindex_file=$1
    local current_dir=$2

    while IFS= read -r line; do
        if [[ $line =~ href=\"([^\"]+)\" ]]; then
            local href="${BASH_REMATCH[1]}"
            local name=$(echo "$line" | sed -n 's/.*>\(.*\)<\/a>.*/\1/p')

            if [[ $href == *"dirindex/?version="* && $href == *"&folder="* ]]; then
                # This is a subdirectory
                local encoded_subfolder=$(echo "$href" | sed -n 's/.*&folder=\([^&]*\).*/\1/p')
                local subfolder=$(urldecode "$encoded_subfolder")
                mkdir -p "$subfolder"
                local subindex_file=$(find . -name "index.html?*folder=$encoded_subfolder*" | head -n 1)
                if [ -n "$subindex_file" ]; then
                    mv "$subindex_file" "$subfolder/dirindex.html"
                    process_dirindex "$subfolder/dirindex.html" "$subfolder"
                fi
            elif [[ $href == /api/access/datafile/* ]]; then
                # This is a file
                local old_name=$(basename "$href")
                local new_name=$(echo "$name" | tr -cd '[:alnum:]._-')
                if [ -f "$old_name" ]; then
                    mv "$old_name" "$current_dir/$new_name"
                    echo "Moved and renamed: $old_name -> $current_dir/$new_name"
                else
                    echo "Warning: File '$old_name' not found."
                fi
            fi
        fi
    done < "$dirindex_file"
}

# Change to the escaped_persistentId directory
cd "$escaped_persistentId" || exit 1

# Find the main dirindex file
main_dirindex=$(find . -name "dirindex*" | head -n 1)

if [ -z "$main_dirindex" ]; then
    echo "Error: Main dirindex file not found."
    exit 1
fi

# Process the main dirindex file
process_dirindex "$main_dirindex" "."

# Rename the main dirindex file to dirindex.html
mv "$main_dirindex" "dirindex.html"
echo "Renamed main dirindex file to dirindex.html"

echo "File organization complete."
