# DVCLI Storage Drivers
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how to list the storage drivers available in a
# Dataverse instance.

# First, we need to create a collection
dvcli -p local collection create --body ../collections/collection.json --parent root

# List the storage drivers
dvcli -p local admin storage-drivers

# Now, lets set the storage driver for the collection
dvcli -p local admin set-storage --driver LocalStack my_collection

# Lets see if we were successful
dvcli -p local admin get-storage my_collection

# Reset the storage driver for the collection
dvcli -p local admin reset-storage my_collection

# Clean up the collection
dvcli -p local collection delete my_collection
