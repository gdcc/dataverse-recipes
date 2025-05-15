# DVCLI Remote Upload
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how to upload a file from a remote URL to a dataset.
# The remote URL should point to a file that is hosted somewhere on the internet.
# When using a remote url, you need to provide a path and filename for the file
# using the --dv-path flag. Otherwise, DVCLI will not know where to store the
# file in the dataset and throw an error.

# Upload the file from a remote URL
REMOTE_URL=https://raw.githubusercontent.com/gdcc/rust-dataverse/refs/heads/master/Readme.md

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Upload the file from a remote URL
dvcli -p local dataset upload \
    --id $dataset_pid \
    --dv-path readme.md \
    $REMOTE_URL

# List the files in the dataset
dvcli -p local dataset list-files $dataset_pid

# Clean up the response file
rm dataset_response.json
