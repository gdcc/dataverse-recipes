# DVCLI Dataset Metadata
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can get the metadata for a dataset.

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Get the metadata for the dataset
dvcli -p local dataset meta $dataset_pid

# Clean up the response file
rm dataset_response.json
