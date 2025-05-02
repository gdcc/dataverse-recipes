#!/bin/bash

# Check if the input file and persistentId are provided
if [ $# -ne 2 ]; then
    echo "Download the files from a Dataverse dataset"
    echo "Currently only works for the latest published dataset version and public (non-restricted, non-embargoed) files"
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

# Change to the escaped_persistentId directory
cd "$escaped_persistentId" || exit 1

# Function to process an index file
process_index() {
    local index_file=$1
    local folder=$2

    if [ -n "$folder" ]; then
        mkdir -p "$folder"
    fi

    while IFS= read -r line; do
        if [[ $line =~ href=\"(/api/access/datafile/[^\"]+)\" ]]; then
            local href="${BASH_REMATCH[1]}"
            local name=$(echo "$line" | sed -n 's/.*>\(.*\)<\/a>.*/\1/p')
            local old_name=$(basename "$href")
            local new_name=$(echo "$name" | tr -cd '[:alnum:]._-')

            if [ -f "$old_name" ]; then
                if [ -n "$folder" ]; then
                    mv "$old_name" "$folder/$new_name"
                    echo "Moved and renamed: $old_name -> $folder/$new_name"
                else
                    mv "$old_name" "$new_name"
                    echo "Renamed: $old_name -> $new_name"
                fi
            else
                echo "Warning: File '$old_name' not found."
            fi
        fi
    done < "$index_file"
}

# Find and process the main dirindex file
main_dirindex=$(find . -name "dirindex*" | head -n 1)

if [ -z "$main_dirindex" ]; then
    echo "Error: Main dirindex file not found."
    exit 1
fi

# Process the main dirindex file
process_index "$main_dirindex"
rm "$main_dirindex"

# Find and process all index.html files
for index_file in index.html?*; do
    if [[ -f "$index_file" ]]; then
        folder=$(echo "$index_file" | sed -n 's/.*folder=\([^&]*\).*/\1/p')
        folder=$(urldecode "$folder")
        process_index "$index_file" "$folder"
        rm "$index_file"
    fi
done

echo "File organization complete."
