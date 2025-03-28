# Upload files using S3 direct upload

A BASH utility function used to ease the direct upload of files to Amazon S3 and the registration to a Dataverse dataset.

## Usage

There is a bash shell script under this directory named **`upload_files_to_dataverse.sh`** which can be executed in a terminal (either in a local or a remote enviornment) to initiate the transfer.

The code can be run in this way:

```
bash upload_files_to_dataverse.sh
```

## Modifying File Type

By default, the script looks for .nc files when uploading to Dataverse. If you need to upload a different file type, update the following line in the script:

```bash
for FILE_PATH in "$SOURCE_FOLDER"/*.nc; do
```

| File Type | Modification Example |
|-----------|----------------------|
| **CSV**   | `for FILE_PATH in "$SOURCE_FOLDER"/*.csv; do` |
| **TXT**   | `for FILE_PATH in "$SOURCE_FOLDER"/*.txt; do` |
| **JSON**  | `for FILE_PATH in "$SOURCE_FOLDER"/*.json; do` |
| **All Files** | `for FILE_PATH in "$SOURCE_FOLDER"/*; do` |

## Configuration Variables

Before running the script, update the following variables to match your environment.

| Variable         | Description |
|-----------------|-------------|
| **`API_TOKEN`** | Your API token, obtainable from your Harvard Dataverse profile page. |
| **`DATAVERSE_URL`** | The Dataverse server URL (default: `https://dataverse.harvard.edu`). |
| **`DATASET_PID`** | The DOI of your dataset registered on Dataverse (e.g., `doi:10.7910/DVN/6QOCNF`). |
| **`SOURCE_FOLDER`** | The folder containing the files to be uploaded and registered on Dataverse. |





