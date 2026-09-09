# Create a dataset with pyDataverse

This recipe creates a dataset in a Dataverse collection using [`pyDataverse`](https://github.com/gdcc/pyDataverse).

## Switch to Python 3.13

Python 3.14 is known not to work. See https://github.com/gdcc/pyDataverse/issues/240

## Set up the virtual environment

From the repository root:

```bash
cd python/create_dataset
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Configure authentication

Because we are creating a dataset, an API token is required.

Get an API token from your Dataverse account and export it as an environment variable. This is more secure than adding the API token to the script itself.

```bash
export API_TOKEN="your-dataverse-api-token"
```

The account associated with the token must have permission to create datasets in the target collection.

By default, the script connects to `https://demo.dataverse.org` and creates the
dataset in the root collection. You can override either setting:

```bash
export DATAVERSE_URL="https://beta.dataverse.org"
export COLLECTION="my-collection"
```

`COLLECTION` must be a collection alias, not its display name.

## Run the script

```bash
python create_dataset.py
```