import json
import os
import sys

from pyDataverse.api import NativeApi

try:
    base_url=os.environ['BASE_URL']
    print("Using base URL from $BASE_URL.")
except:
    print("You must define a BASE_URL environment variable.")
    exit(1)

try:
    api_token=os.environ['API_TOKEN']
    print("Using API token from $API_TOKEN.")
except:
    print("You must define a API_TOKEN environment variable.")
    exit(1)

try:
    collection=os.environ['COLLECTION']
    print("Using collection (dataverse) from $COLLECTION.")
except:
    print("You must define a COLLECTION environment variable.")
    exit(1)

if len(sys.argv) < 2:
    print("Usage: python create_dataset.py <json_file>")
    exit(1)

json_file = sys.argv[1]
with open(json_file, 'r') as f:
    json_in = json.load(f)

api = NativeApi(base_url, api_token)
print("Printing version of Dataverse")
print(api.get_info_version().json())

print("Creating a dataset in collection " + collection)
resp = api.create_dataset(collection, json_in, publish=False)
print(resp.json())
