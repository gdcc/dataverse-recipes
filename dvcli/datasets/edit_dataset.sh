# DVCLI Edit Dataset
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can edit a dataset. We do this by providing
# a body which contains all the metadata that should either be replaced or added.
#
# Please be aware, that you have two options to edit a dataset. You can either
# edit the dataset in the current state or you can edit the dataset and set the
# state to draft. We will utilize the non-replace way to demonstrate a simple
# edit.

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Edit the dataset
dvcli -p local dataset edit --pid $dataset_pid --body bodies/edit.json

# Get the metadata for the dataset, you should see the changes
dvcli -p local dataset meta $dataset_pid

# Clean up the response file
rm dataset_response.json
