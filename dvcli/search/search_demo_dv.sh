# DVCLI Search Demo
#
# Please note, this recipe uses the environment variable DVCLI_URL to connect
# to the Dataverse instance. If you do not have this variable set, please set
# it to the URL of your Dataverse instance. Alternatively, you can use the
# authentication.sh recipe to authenticate to the Dataverse instance.
#
# This script demonstrates how you can search for datasets using DVCLI.

export DVCLI_URL=https://dataverse.harvard.edu

# Search for datasets
dvcli search --query "PyDataverse"

# Please note, the search command features a lot of different options.
# To get an overview of the different options, please refer to the following link:
#
# https://docs.dataverse.org/en/latest/api/native-api.html#search-api
#
# or use the --help flag to get more information.

dvcli search --help
