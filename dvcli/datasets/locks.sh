# DVCLI Dataset Locks
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can check the lock status of a dataset. We
# will demonstrate how to lock a dataset manually and then how to unlock it.

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Set all the locks that are possible
dvcli -p local dataset locks --set --type Ingest $dataset_pid
dvcli -p local dataset locks --set --type Workflow $dataset_pid
dvcli -p local dataset locks --set --type InReview $dataset_pid
dvcli -p local dataset locks --set --type FinalizePublication $dataset_pid
dvcli -p local dataset locks --set --type EditInProgress $dataset_pid

# Lets check the lock status, should list the lock
dvcli -p local dataset locks $dataset_pid

# You can also check the lock status for a specific type
dvcli -p local dataset locks --type InReview $dataset_pid

# Once you are done, you can unlock specific locks
dvcli -p local dataset locks --remove --type InReview $dataset_pid

# Lets verify that there is no InReview lock (should return an empty list)
dvcli -p local dataset locks --type InReview $dataset_pid

# Clean up the response file
rm dataset_response.json
