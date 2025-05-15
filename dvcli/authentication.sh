# DVCLI Authentication
#
# In order to re-use the same token for multiple commands, you can save
# your token/url combination as a profile in your local keychain. Once used
# your system will prompt you to allow dvcli to access your keychain.

TOKEN=XXXX-XXXX
URL=https://demo.dataverse.org
PROFILE=myprofile

dvcli auth set --name $PROFILE --token $TOKEN --url $URL

# Example usage of how to use the profile
dvcli -p $PROFILE info version

# Alternatively, you can set the token as an environment variable
export DVCLI_TOKEN="<TOKEN>"
export DVCLI_URL="<URL>"

# Then you can use the token without the profile
dvcli info version
