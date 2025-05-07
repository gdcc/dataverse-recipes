# Dataverse Dataset Downloader

## Purpose

The Dataverse Dataset Downloader is a shell script that automates the process of downloading files from a Dataverse dataset and organizing them into their respective folders.
It's particularly useful when the dataset has many files and/or a directory structure that needs to be preserved.


## Features

- Downloads files from the specified Dataverse dataset
- Names and organizes files into their respective folders as in the specified dataset version
- Provides progress feedback during the download
- Tracks successful file downloads and can be restarted after interuption/failure where it left off
- Supports downloading specific versions of a dataset including drafts
- Allows access to restricted files with an API key
- Option to continue downloading even if some files are forbidden, i.e. if you have access to some but not all files in the dataset
- Configurable wait time between downloads to respect server rate limits

## Prerequisites

- Bash shell (Linux or macOS)
- `wget`
- `grep`
- `sed`

The script checks for these dependencies and will notify you if any are missing.

## Usage
./dv_downloader.sh <server> <persistentId> [--wait=<wait_time>] [--apikey=<api_key>] [--version=<version>] [--ignoreForbidden]

### Parameters:

- `<server>`: The base URL of the Dataverse server
- `<persistentId>`: The persistent identifier of the dataset

### Optional Parameters:

- `--wait=<wait_time>`: Time in seconds to wait between file downloads (can be a fraction)
- `--apikey=<api_key>`: API key for accessing restricted or embargoed files
- `--version=<version>`: Specific version to download (e.g., '1.2' or ':draft')
- `--ignoreForbidden`: Continue downloading even if some files return a 403 Forbidden error - required if you do not have access to all files in the dataset

### Example:

./dv_downloader.sh https://demo.dataverse.org doi:10.5072/F2ABCDEF --wait=0.75 --apikey=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --version=1.2 --ignoreForbidden

## Output

The script creates a new directory named after the persistent identifier (with forward slashes replaced by underscores) and organizes all downloaded files within this directory. If a specific version is requested, it's appended to the directory name.

## Error Handling

- The script will exit if it fails to download the main directory index
- By default, it will exit if it encounters a 403 Forbidden error, unless the `--ignoreForbidden` flag is used
- It provides informative error messages and suggests retrying in case of temporary network issues or rate limiting

## Notes

- The script resumes interrupted downloads, so you can safely re-run it if it gets interrupted. You may need to wait if the issue is rate limiting at the server, or you may need to add the ignoreForbidden flag if you do not have access to all files.
- It keeps track of downloaded files to avoid unnecessary re-downloads. Deleting the directory for the dataset will also clear progress tracking.
- Use the `--wait` option to add a delay between downloads if you're concerned about server load or rate limiting. <tracking period in minutes * 60)/<API calls allowed>, e.g. 0.75 seconds for a rate limit of 400 api calls over 5 minutes should be a conservative estimate of what's needed with small files.
