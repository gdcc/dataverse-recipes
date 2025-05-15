# DVCLI Replace File
#
# Please note, we are using the environment variable DVCLI_URL to connect
# to the Dataverse instance. If you do not have this variable set, please set
# it to the URL of your Dataverse instance. Alternatively, you can use the
# authentication.sh recipe to authenticate to the Dataverse instance.
#
# This script demonstrates how you can replace a file in a dataset.

export DVCLI_URL=https://darus.uni-stuttgart.de

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Upload a file to the dataset
dvcli -p local dataset upload --id $dataset_pid data/upload.txt

# Fetch the file id
file_id=$(dvcli -p local dataset list-files $dataset_pid | jq -r '.["upload.txt"].dataFile.id')

# Replace the file
dvcli -p local file replace --id $file_id data/to_replace.txt

# Clean up
rm dataset_response.json
