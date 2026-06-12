# Add Remote Files to Dataverse

This script registers files in a local directory tree as remote-store references in a Dataverse dataset.

## Overview

No file bytes are transferred; only metadata (storage identifier, filename, MIME type, MD5 hash) is sent to the Dataverse API.

Dataverse and the specific dataset must be configured to use a remote store - see https://guides.dataverse.org/en/latest/installation/config.html#trusted-remote-storage 

## Prerequisites

- Python 3.x
- Dataverse API Token
- A dataset configured for a remote store

## Installation

This script uses only the Python standard library, so no external dependencies are required.

```bash
python3 -m venv venv
# On Windows
venv\Scripts\activate
# On macOS/Linux
source venv/bin/activate
```

## Usage

```bash
python add_remote_files.py \
    --server    https://dataverse.example.org \
    --api-key   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    --store-id  trs \
    --web-root /mnt/data \
    --pid       doi:10.5072/FK27U7YBV \
    --base-dir  /mnt/data/project/files
```

### Parameters

- `--server`: Base URL of the Dataverse server.
- `--api-key`: Your Dataverse API token.
- `--store-id`: Remote store ID configured in Dataverse (e.g., `trs`).
- `--web-root`: Local path prefix corresponding to the website root directory.
- `--pid`: Dataset persistent identifier (e.g., DOI).
- `--base-dir`: Local directory tree to scan for files.
- `--limit`: (Optional) Only register the first N files that don't exist on the server.
- `--dry-run`: (Optional) Build and print the JSON payload without calling the API.
- `--batch-size`: (Optional) Number of files to send per API call (default: 100).

## How it works

1. The script scans the `--base-dir` for all files.
2. It fetches the existing file list from the Dataverse dataset to avoid duplicates.
3. For each file, it:
   - Constructs a `storageIdentifier` and checks if it already exists in the dataset.
   - Calculates the MD5 hash (only for new files).
   - Guesses the MIME type.
   - Determines the `directoryLabel` based on the relative path from `--web-root`.
4. If `--limit` is specified, it stops after finding the requested number of new files.
5. It sends the metadata in batches to the Dataverse `addFiles` API.
