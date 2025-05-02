# Dataverse Dataset Downloader

## Purpose

The Dataverse Dataset Downloader is a shell script that automates the process of downloading files from a Dataverse dataset and organizing them into their respective folders.
It's particularly useful when the dataset has many files and/or a directory structure than needs to be preserved.

## Prerequisites

- Bash shell (Linux or macOS)
- `wget`
- `grep`
- `sed`

The script checks for these dependencies and will notify you if any are missing.

## Usage
./DVDownload.sh <server> <persistentId>

### Parameters:

- `<server>`: The base URL of the Dataverse server
- `<persistentId>`: The persistent identifier of the dataset

### Example:

./DVDownload.sh https://demo.dataverse.org doi:10.5072/F2ABCDEF

## Features

- Downloads all public, non-restricted, non-embargoed, non-expired files from the latest published version of the specified Dataverse dataset
- Organizes files into their respective folders as structured in the original dataset
- Renames files to their original names
- Provides progress feedback during the download and organization process

## Output

The script creates a new directory named after the persistent identifier (with forward slashes replaced by underscores) and organizes all downloaded files within this directory.

