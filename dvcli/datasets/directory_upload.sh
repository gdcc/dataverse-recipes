# DVCLI Directory Upload
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script will upload a directory to a dataset. DVCLI will create
# a zip stream of the directory and upload it to the dataset. This is a quick
# and efficient way to upload a large number of files to a dataset without the
# need to zip the files manually.

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Upload the directory
dvcli -p local dataset upload --id $dataset_pid data/

# List the files in the dataset
dvcli -p local dataset list-files $dataset_pid

# Clean up the response file
rm dataset_response.json
