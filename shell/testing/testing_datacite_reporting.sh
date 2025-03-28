#!/bin/bash

# Datacite Reporting Script
# This script checks Datacite reports for a specific date and analyzes dataset usage statistics
# It handles report retrieval, data analysis, and notification of empty instance arrays

# Logging configuration
LOGFILE="datacite_reporting.log"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to check for errors and exit if found
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1. Exiting."
        exit 1
    fi
}

# Function to check for required commands
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "curl" "jq" "mail" "date" "wc"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "Error: The following required commands are not installed:"
        printf ' - %s\n' "${missing_commands[@]}" | tee -a "$LOGFILE"
        echo
        log "Please install these commands before running the script."
        log "On Debian/Ubuntu systems, you can install them with:"
        log "sudo apt-get install curl jq mailutils"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install curl jq mailx"
        exit 1
    fi
}

# Load environment variables from .env file
if [ -f "$(dirname "$0")/.env" ]; then
    log "Loading environment variables from .env file..."
    source "$(dirname "$0")/.env"
else
    log "Error: .env file not found in $(dirname "$0")"
    log "Please copy sample.env to .env and update the values."
    exit 1
fi

# Validate required environment variables
required_vars=(
    "DATACITE_ORG"
    "EMAIL_RECIPIENT"
)

# Set YESTERDAY to the desired date (default: yesterday)
YESTERDAY=$(date -v-1d +%Y-%m-%d)
echo "Checking reports for date: $YESTERDAY"

# Get all reports, find the one whose end-date is $YESTERDAY, extract the report ID
REPORTS_JSON=$(curl -s "https://api.datacite.org/reports?created_by=$DATACITE_ORG")

# Check if we got any reports at all
if [ "$(echo "$REPORTS_JSON" | jq -r '.reports')" == "null" ]; then
    echo "No reports found in the response."
    exit 0
fi

REPORT_ID=$(echo "$REPORTS_JSON" | jq -r --arg YESTERDAY "$YESTERDAY" '.reports[]
  | select(.["report-header"]["reporting-period"]["end-date"] == $YESTERDAY)
  | .id')

if [ -z "$REPORT_ID" ]; then
  echo "No report found for end-date $YESTERDAY."
  exit 0
fi

echo "Found report ID: $REPORT_ID"

# Use the ID to fetch the specific report
REPORT_JSON=$(curl -s "https://api.datacite.org/reports/$REPORT_ID")

# Check if report-datasets exists and is not null
if [ "$(echo "$REPORT_JSON" | jq '.report["report-datasets"][].performance[] | {period, instance}')" == "null" ]; then
    echo "Error:Report exists but contains no datasets."
    exit 0
fi

# Get total number of datasets
LIST_DATASETS=$(echo "$REPORT_JSON" | jq '.report["report-datasets"][].performance[].instance[] | select(.["metric-type"] == "unique-dataset-investigations") | .count')
TOTAL_DATASET_VIEWS=$(echo "$LIST_DATASETS" | jq -s add)
TOTAL_DATASETS=$(echo "$LIST_DATASETS" | wc -l)
echo "Total number of datasets in report: $TOTAL_DATASETS"
echo "Total number of datasets views in report: $TOTAL_DATASET_VIEWS"

if [ "$TOTAL_DATASETS" -eq 0 ]; then
    echo "Report exists but contains no datasets."
    exit 0
fi

# Check datasets with their instance arrays
DATASETS_WITH_INSTANCES=$(echo "$REPORT_JSON" | jq '
    .report["report-datasets"][].performance[] | {period, instance}' | wc -l)

DATASETS_WITHOUT_INSTANCES=$(echo "$REPORT_JSON" | jq '
    .report["report-datasets"][].performance[] | select(.instance == []) | {period, instance}' | wc -l)

echo "Datasets with non-empty instance arrays: $DATASETS_WITH_INSTANCES"
echo "Datasets with empty instance arrays: $DATASETS_WITHOUT_INSTANCES"

# Only show detailed empty instance data if there are any
if [ "$DATASETS_WITHOUT_INSTANCES" -gt 0 ]; then
    echo -e "\nDetailed list of datasets with empty instance arrays:"
    echo "$REPORT_JSON" | jq '.report["report-datasets"][] | {
        "dataset-title": .["dataset-title"],
        "dataset-id": .["dataset-id"],
        "uri": .uri,
        "performance": [.performance[] | {period, instance}]
    }'
fi

# If Total number of datasets in report isn't 0 and there are datasets with empty instance arrays, send an email
if [ "$TOTAL_DATASETS" -ne 0 ] && [ "$DATASETS_WITHOUT_INSTANCES" -gt 0 ]; then
  echo "Sending email to $EMAIL_RECIPIENT"
  echo "Subject: Dataverse Report for $YESTERDAY" | mail -s "Dataverse Report for $YESTERDAY" $EMAIL_RECIPIENT
fi
