# DVCLI Collection Creation and Publishing
#
# Please note, this recipe assumes that you are already familiar with
# DVCLI authentication. If you are not, please refer to the authentication.sh
# recipe or use the environment variables DVCLI_TOKEN and DVCLI_URL.
#
# This script demonstrates how to create a collection and publish it.
# Finally, it checks the content of the collection and deletes it.

# Create a collection
dvcli -p local collection create --body collection.json --parent root

# Publish the collection
dvcli -p local collection publish my_collection

# Check the content of the collection - Should be empty
dvcli -p local collection content my_collection

# Delete the collection
dvcli -p local collection delete my_collection
