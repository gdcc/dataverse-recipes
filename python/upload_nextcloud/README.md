# Nextcloud Data Transfer Script

This directory contains a script `transfer.py` to transfer data from a Nextcloud link share into a target dataset.

## Installation

You have a few choices. You can use pip, pipx, uv or poetry.
The simplest way to go about this:

1. Run `pip install git+https://github.com/gdcc/dataverse-recipes.git@main#subdirectory=python/upload_nextcloud`
2. Run `nc-transfer` (the installed package will create this wrapper for you)

## Usage

```text
$ transfer.py --help
usage: transfer.py [-h] [--share SHARE] [--subpath SUBPATH] [--instance INSTANCE] [--api-token API_TOKEN]
                   [--dataset-doi DATASET_DOI] [--skip-existing] [--temp-dir TEMP_DIR]
                   [--journal-file JOURNAL_FILE] [--verbose] [--env-file ENV_FILE]

Transfer files from Nextcloud link share to Dataverse

options:
  -h, --help            show this help message and exit
  --share SHARE         (Req.) Nextcloud public share URL (e.g., https://cloud.example.com/s/sHaReToKeN).
                        Can be set as env var NEXTCLOUD_SHARE_URL.
  --subpath SUBPATH     (Opt.) Subpath within the Nextcloud share to start the file tree traversal from
  --instance INSTANCE   (Req.) Dataverse instance URL (e.g., https://demo.dataverse.org). Can be set as
                        env var DATAVERSE_URL.
  --api-token API_TOKEN
                        (Req.) Dataverse API Token. Superadmin or other with permissions for dataset. Can
                        be set as env var DATAVERSE_API_TOKEN.
  --dataset-doi DATASET_DOI
                        (Req.) Target dataset DOI (e.g., doi:10.1234/5678). Can be set as env var
                        DATASET_DOI.
  --skip-existing       (Opt.) Skip files that have already been uploaded to the dataset (default: exit
                        with error)
  --temp-dir TEMP_DIR   Temporary directory for downloads (default: system temp)
  --journal-file JOURNAL_FILE
                        Journal file to track progress (default: transfer_journal.txt)
  --verbose             Enable verbose logging output
  --env-file ENV_FILE   Path to .env file (default: .env in current directory)
```

### Example

To transfer all files in a link share at `https://cloud.example.org/s/TLbS3JtOJ6NXADe`, follow these steps:

1. Have your target installation URL and dataset DOI at the ready. For this example, let's assume:  
   - Installation URL: `https://dataverse.example.org`
   - Dataset DOI: `doi:10.1234/foobar/123456`
2. Ensure you have an API Token and appropriate permissions on the dataset. You can create or look up the token at `https://dataverse.example.org/dataverseuser.xhtml?selectTab=apiTokenTab`.
3. To avoid saving secrets in your shell history, use a `.env` file:
   ```plain
   DATAVERSE_API_TOKEN=1234-5678-9012
   DATAVERSE_URL=https://dataverse.example.org
   ```
   You can add more options, see help text above. In case of multiple activities, this shortens the CLI commands.
4. Now start the transfer:
   ```shell
   $ nc-transfer \
     --share "https://cloud.example.org/s/TLbS3JtOJ6NXADe" \
     --dataset-doi "doi:10.1234/foobar/123456" \ 
   ```

A transfer log will be created to avoid re-transferring files successfully copied.

Have fun!


