# DVCLI Dataset Submit Review
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how you can submit a dataset for review.
#
# This script will:
# 1. Create a dataset
# 2. Submit the dataset for review
# 3. Check the lock status
# 4. Return to the author and unlock the dataset
# 5. Check the lock status again
# 6. Clean up the response file

# Create a dataset
dvcli -p local dataset create --body bodies/dataset.json --collection root >dataset_response.json

# Grab the dataset pid from the response
dataset_pid=$(jq -r '.persistentId' dataset_response.json)

# Submit the dataset for review
dvcli -p local dataset review --submit $dataset_pid

# Lets check the lock status, should list the lock
dvcli -p local dataset locks --type InReview $dataset_pid

# Now, lets return to the author and unlock the dataset
dvcli -p local dataset review \
    --reason "Dataset should be checked for compliance" \
    $dataset_pid

# Lets check the lock status again, should be unlocked
dvcli -p local dataset locks --type InReview $dataset_pid

# Clean up the response file
rm dataset_response.json
