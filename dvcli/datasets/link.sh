# DVCLI Dataset Link
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can link a dataset to another collection.
# We will first create a collection, then create a dataset at root and link the dataset
# to the collection.

COLLECTION_NAME="upload_collection"
PARENT_COLLECTION="root"

# Create a collection
dvcli -p local collection create --body bodies/collection.json --parent $PARENT_COLLECTION
dvcli -p local collection publish $COLLECTION_NAME

# Create a dataset at root
dvcli -p local dataset create --body bodies/dataset.json --collection $PARENT_COLLECTION >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Publish the dataset
dvcli -p local dataset publish $dataset_pid

# Link the dataset to the collection
dvcli -p local dataset link --collection $COLLECTION_NAME --id $dataset_pid

# Clean up the response file
rm dataset_response.json
