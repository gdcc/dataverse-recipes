# DVCLI Format Export
#
# Please note, we are using the environment variable DVCLI_URL to connect
# to the Dataverse instance. If you do not have this variable set, please set
# it to the URL of your Dataverse instance. Alternatively, you can use the
# authentication.sh recipe to authenticate to the Dataverse instance.
#
# This script demonstrates how you can export a dataset to a file in a
# specific format.

export DVCLI_URL=https://dataverse.harvard.edu

# List all available formats
dvcli info exporters

# Export the dataset to a file in a specific format
dvcli dataset export --format croissant --id doi:10.7910/DVN/2SYD32 --out download/croissant.json

# DVCLI checks if the given format already exists, if not it will throw an error
dvcli dataset export --format invalid --id doi:10.7910/DVN/2SYD32 --out download/invalid.json
