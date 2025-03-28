#!/bin/bash

# 🔹 Set your Dataverse API credentials
API_TOKEN="XXXXXXXXXXXXXXXXXXXXXXXXXXXX"  # Replace with your actual API token
DATAVERSE_URL="https://dataverse.harvard.edu"  # Adjust if using a different Dataverse
DATASET_PID="doi:10.7910/DVN/XXXXXX"  # Replace with your dataset's persistent ID
# 🔹 Set the folder containing NetCDF files
SOURCE_FOLDER="/discover/nobackup/asouri/PROJECTS/PO3_ACMAP/ozonerates/PO3_TROPOMI/"

# Loop through all NetCDF (.nc) files in the folder
for FILE_PATH in "$SOURCE_FOLDER"/*.nc; do
    # Check if the file exists (handles case where no .nc files are found)
    if [[ ! -f "$FILE_PATH" ]]; then
        echo "No NetCDF files found in $SOURCE_FOLDER. Exiting."
        exit 1
    fi

    echo "Processing file: $FILE_PATH"

    # === STEP 1: REQUEST S3 UPLOAD URL FROM DATAVERSE ===
    echo "Requesting S3 upload URL from Dataverse..."
    UPLOAD_RESPONSE=$(curl -s -X GET "$DATAVERSE_URL/api/datasets/:persistentId/uploadurls?persistentId=$DATASET_PID" \
        -H "X-Dataverse-key: $API_TOKEN")

    # Extract the S3 upload URL and storage identifier
    URL_AMAZON=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.url')
    STORAGE_IDENTIFIER=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.storageIdentifier')

    if [[ -z "$URL_AMAZON" || "$URL_AMAZON" == "null" ]]; then
        echo "Error: Failed to get an S3 upload URL from Dataverse for $FILE_PATH."
        echo "Response: $UPLOAD_RESPONSE"
        continue  # Skip to next file instead of exiting
    fi

    echo "S3 upload URL obtained successfully."

    # === STEP 2: UPLOAD FILE DIRECTLY TO S3 ===
    echo "Uploading file directly to S3..."
    S3_UPLOAD_RESPONSE=$(curl -i -H 'x-amz-tagging:dv-state=temp' -X PUT -T "$FILE_PATH" "$URL_AMAZON")

    if [[ $? -ne 0 ]]; then
        echo "Error: File upload to S3 failed for $FILE_PATH."
        continue  # Skip to next file
    fi

    echo "File successfully uploaded to S3."

   # === STEP 3: REGISTER FILE IN DATAVERSE ===
    echo "Registering file with Dataverse..."
    FILE_NAME=$(basename "$FILE_PATH")

    # Generate a SHA-1 checksum of the file
    CHECKSUM_VALUE=$(sha1sum "$FILE_PATH" | awk '{print $1}')

    # Create JSON data for file registration
    JSON_DATA=$(jq -n \
      --arg desc "NetCDF file upload." \
      --arg dirLabel "data/netcdf" \
      --argjson categories '["Data"]' \
      --arg restrict "false" \
      --arg storageId "$STORAGE_IDENTIFIER" \
      --arg fileName "$FILE_NAME" \
      --arg mimeType "application/x-netcdf" \
      --arg checksumType "SHA-1" \
      --arg checksumValue "$CHECKSUM_VALUE" \
      '{
        description: $desc,
        directoryLabel: $dirLabel,
        categories: $categories,
        restrict: $restrict,
        storageIdentifier: $storageId,
        fileName: $fileName,
        mimeType: $mimeType,
        checksum: { "@type": $checksumType, "@value": $checksumValue }
      }')

    # Register the file in Dataverse
    REGISTER_RESPONSE=$(curl -s -X POST "$DATAVERSE_URL/api/datasets/:persistentId/add?persistentId=$DATASET_PID" \
        -H "X-Dataverse-key: $API_TOKEN" \
        -H "Content-Type: multipart/form-data" \
        -F "jsonData=$JSON_DATA")

    # Check for errors
    if [[ $(echo "$REGISTER_RESPONSE" | jq -r '.status') == "ERROR" ]]; then
        echo "Error: Failed to register file in Dataverse for $FILE_NAME."
        echo "Response: $REGISTER_RESPONSE"
        continue  # Skip to next file
    fi

    echo "File $FILE_NAME successfully registered in Dataverse!"
done

echo "All files processed."
