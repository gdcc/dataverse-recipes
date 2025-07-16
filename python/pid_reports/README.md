# PID Reports

## Overview

This folder contains scripts that generate reports on Persistent Identifier (PID) usage in a Dataverse instance. These scripts specifically identify cases where PIDs were not found, which may indicate:

- In-the-wild use of draft PIDs
- Posting of PIDs with typos
- PIDs with extra characters (e.g., trailing periods)
- Other malformed PID references

## Scripts

The main script in this folder is `dcpidreport.py`, which checks DataCite for DOI resolution and generates reports on failures. Anything reported via this script indicates that someone tried to resolve the specified DOI, i.e. via https://doi.org/* . DataCite can sometimes be more than a month delayed in updating its reports - the script is able to handle this.

A second script, `pidreport.py` performs similar functions for any PIDs. However, it relies on functionality to create an initial PIDFailures report that is not yet merged into the standard Dataverse distribution from https://github.org/IQSS/dataverse.
The benefit of this message is that the results are available every month and they capture any call to Dataverse requiring a PID (i.e. where someone may have posted a direct, incorrect link to a dataset page, versus DataCite only reporting DOI resolution failures).

## Purpose

These reports help maintain the integrity of your Dataverse's persistent identifier system by:
- Identifying problematic PID references
- Alerting administrators to potential issues
- Providing data for troubleshooting and correction

## Usage

The scripts are designed to be run periodically (typically monthly) via a cron job.

### Configuration

Before using these scripts, you need to configure several variables in each script:

#### For dcpidreport.py:

1. **File paths**:
   - Update the `filename` variable to point to your desired state file location

2. **Dataverse configuration**:
   - `doi_account`: Your DataCite account prefix (e.g., "GDCC.YOUR_ACCOUNT")
   - `dataverse_base_url`: The base URL of your Dataverse installation (e.g., "https://data.yourdataverse.org")

3. **Email configuration**:
   - `receivers`: Email addresses that should receive the reports
   - `smtp_server`: Your SMTP server address
   - `port`: SMTP port (default is 465 for SSL)
   - `sender_email`: Email address from which reports will be sent
   - `username`: SMTP authentication username
   - `password`: SMTP authentication password

#### For pidreport.py:

1. **File paths**:
   - `log_dir`: Directory where PID failure logs are stored

2. **Dataverse configuration**:
   - `dataverse_base_url`: The base URL of your Dataverse installation

3. **Email configuration**:
   - Same as dcpidreport.py (receivers, smtp_server, port, sender_email, username, password)

4. **IP blacklist configuration**:
   - `blacklist`: List of IP addresses to exclude from reports (e.g., known scanners such as UT Dorkbot / autoscan.infosec.utexas.edu that test with incorrect PIDs)

### Cron Configuration

To set up a monthly cron job that runs on the 1st day of each month, add something similar to the following to your crontab:

10 5 1 * * python3 /opt/pidreporting/pidreport.py >> /var/log/pidreport.log 2>&1
12 5 1 * * /usr/bin/python3 /opt/pidreporting/dcpidreport.py >> /var/log/dcpidreport.log 2>&1

