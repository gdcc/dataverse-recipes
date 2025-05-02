#!/bin/bash

# Check if the input file and persistentId are provided
if [ $# -ne 1 ]; then
    echo "Download the files from a Dataverse dataset"
    echo "Currently only works for the latest published dataset version and public (non-restricted, non-empbargoed) files without a path/directoryLabel"

    echo "Usage: $0 <persistentId>"
    echo "persistentId should be of the form doi:10.5072/F2ABCDEF"
    exit 1
fi

persistentId="$1"

# Execute wget command
wget -nd -mpF -e robots=off -P "$persistentId" "https://dv.dev-aws.qdr.org/api/datasets/:persistentId/dirindex?persistentId=$persistentId"

# Change to the persistentId directory
cd "$persistentId" || exit 1

# Find the dirindex file
dirindex_file=$(find . -name "dirindex*" | head -n 1)

if [ -z "$dirindex_file" ]; then
    echo "Error: dirindex file not found."
    exit 1
fi

# Read the dirindex file line by line
while IFS= read -r line; do
    # Extract the href attribute value and get only the filename
    old_name=$(echo "$line" | sed -n 's/.*href="[^"]*\/\([^"]*\)".*/\1/p')

    # Extract the text content of the 'a' element
    new_name=$(echo "$line" | sed -n 's/.*>\(.*\)<\/a>.*/\1/p')

    # Check if both old_name and new_name are non-empty
    if [ -n "$old_name" ] && [ -n "$new_name" ]; then
        # Remove any special characters and spaces from the new name
        new_name=$(echo "$new_name" | tr -cd '[:alnum:]._-')

        # Check if the old file exists
        if [ -f "$old_name" ]; then
            # Rename the file
            mv "$old_name" "$new_name"
            echo "Renamed: $old_name -> $new_name"
        else
            echo "Warning: File '$old_name' not found."
        fi
    fi
done < "$dirindex_file"

echo "File renaming complete."
