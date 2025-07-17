# DVCLI Hello World
#
# Welcome to DVCLI! This is a simple script that will help you get started
# with DVCLI and perform the unofficial "Hello World" of DVCLI.

# We will fall back to using the environment variables DVCLI_TOKEN and DVCLI_URL
# but for good measure, you should take a look at the authentication.sh recipe, which
# demonstrates how you can store your credentials safely on your system.

export DVCLI_URL=https://demo.dataverse.org

# Print the version of Demo Dataverse
dvcli info version
