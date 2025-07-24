# DVCLI Dataset Creation, Upload, and Publishing
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how to create a dataset, upload a file to it,
# publish the dataset, and then delete it.

# Create a dataset
#
# This step also demonstrates that you can override the terminal output
# and save the response to a file. We will use this file in the next step.
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Tip: DVCLI supports both persistent and database IDs. But be
# aware that the database ID can change, compared to the persistent ID.
# dataset_pid=$(jq -r '.id' dataset_response.json)

# Upload an example file
dvcli -p local dataset upload --id $dataset_pid data/example.txt

# List the metadata for the dataset
dvcli -p local dataset meta $dataset_pid

# List the files for the dataset
dvcli -p local dataset list-files $dataset_pid

# Publish the dataset
dvcli -p local dataset publish $dataset_pid

# Clean up the response file
rm dataset_response.json
