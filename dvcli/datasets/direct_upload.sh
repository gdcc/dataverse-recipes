# DVCLI Direct Upload
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how to perform a direct upload to a dataset,
# which is particularly useful for uploading large files to a dataset.
# DVCLI maintains a database to track the upload progress. If the upload
# is interrupted, you can resume the upload from the same place.

# IMPORTANT:
# If you are running this script with a local dev environment, you need to
# set the TEST_MODE environment variable to LocalStack. This will convert the
# Docker URLs to the LocalStack URLs. You will not need to do this in a
# production environment.
export TEST_MODE=LocalStack

# Create a collection and set the storage driver to LocalStack (optional)
# This part is meant to test the functionality, but in a real scenario
# you would not need to do this.
dvcli -p local collection create --body bodies/collection.json --parent root
dvcli -p local admin set-storage --driver LocalStack upload_collection

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection upload_collection >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)
dataset_id=$(jq -r '.id' dataset_response.json)

# Perform a direct upload of multiple files
dvcli -p local dataset direct-upload \
    --id $dataset_pid \
    data/example.txt \
    data/tabular.csv

# List the files in the dataset
dvcli -p local dataset list-files $dataset_pid

# Clean up the response file
rm dataset_response.json
