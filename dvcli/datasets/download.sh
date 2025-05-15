# DVCLI Dataset Download
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can download files or the entire dataset
# to your local machine. You have two options:
#
# 1. Download a specific file from the dataset by providing the file id/pid
# 2. Download the entire dataset as a zip file
#
# Downloads are resumable and will pick up where they left off if interrupted.

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Upload a file to the dataset
dvcli -p local dataset upload --id $dataset_pid data/

# Download the complete dataset as a zip file
dvcli -p local dataset download --id $dataset_pid --complete

# Clean up the response file
rm dataset_response.json
