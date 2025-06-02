# Dataverse Production Backup & Fetch Script Documentation

## Overview

The `fetch_prod.sh` script automates the process of syncing a Dataverse instance from a production server to a staging/clone server. It provides a systematic approach to copying database content, files, Solr configuration, and counter processor components, while preserving sensitive configurations on the target server. The script includes robust error handling, disk space checks, and interactive prompts for critical operations.

## Prerequisites

Before running the script, ensure you have:

1. SSH access to the production server with appropriate permissions
2. PostgreSQL client tools installed on the clone server
3. A properly configured `.env` file in the same directory as the script
4. Sufficient disk space to store the production data (the script will check this automatically)
5. PostgreSQL authentication configured correctly for the specified users (passwords are optional; see below)

## Environment Configuration

Create a `.env` file in the same directory as the script with the following required variables:

### Local Environment
- `DOMAIN`: Domain name of the clone/staging server
- `PAYARA`: Path to Payara/Glassfish installation directory
- `DATAVERSE_USER`: System user for Dataverse application
- `SOLR_USER`: System user for Solr
- `DATAVERSE_CONTENT_STORAGE`: Path to Dataverse files
- `SOLR_PATH`: Path to Solr installation
- `DATAVERSE_API_KEY`: API token for enabling metadata blocks (required for metadata block sync)
- `FULL_COPY`: (Optional) Set to "true" for complete file transfer or "false" to limit file sizes to 2MB (maintains directory structure while avoiding large data files for testing)

### S3 Configuration
The script provides three options for handling S3 storage configuration:
1. Configure a new S3 bucket for the clone
2. Switch to local file storage
3. Inherit S3 settings from production (not recommended)

When configuring a new S3 bucket, you'll need to provide:
- Bucket Name
- Region (optional)
- Endpoint URL (optional, for non-AWS S3-compatible storage)

### Optional Counter Processor Variables
- `COUNTER_DAILY_SCRIPT`: Path to counter processor daily script
- `COUNTER_WEEKLY_SCRIPT`: Path to counter processor weekly script
- `COUNTER_PROCESSOR_DIR`: Path to counter processor directory

### Production Environment
- `PRODUCTION_SERVER`: Hostname/IP of the production server
- `PRODUCTION_SSH_USER`: (Optional) SSH user for connecting to production server (defaults to current user if not specified)
- `PRODUCTION_DOMAIN`: Domain name of the production server
- `PRODUCTION_DATAVERSE_USER`: Production system user for Dataverse
- `PRODUCTION_SOLR_USER`: Production system user for Solr
- `PRODUCTION_DATAVERSE_CONTENT_STORAGE`: Path to production Dataverse files
- `PRODUCTION_SOLR_PATH`: Path to production Solr installation

### Optional Production Counter Processor Variables
- `PRODUCTION_COUNTER_DAILY_SCRIPT`: Path to production counter daily script
- `PRODUCTION_COUNTER_WEEKLY_SCRIPT`: Path to production counter weekly script
- `PRODUCTION_COUNTER_PROCESSOR_DIR`: Path to production counter processor directory

### Database Configuration
- `DB_HOST`: Hostname for local database
- `DB_NAME`: Name of the local database
- `DB_USER`: Username for local database
- `PRODUCTION_DB_HOST`: Hostname for production database
- `PRODUCTION_DB_NAME`: Name of production database
- `PRODUCTION_DB_USER`: Username for production database
- `DB_PASSWORD`: (Optional) Password for local database user. Only used if set; otherwise, peer or ident authentication is used.
- `PRODUCTION_DB_PASSWORD`: (Optional) Password for production database user. Only used if set; otherwise, peer or ident authentication is used.

## Command-Line Options

The script supports the following command-line options:

- `--dry-run`: Show what would be done without making changes
- `--verbose`: Show detailed output
- `--skip-db`: Skip database sync
- `--skip-files`: Skip Dataverse files sync
- `--skip-solr`: Skip Solr configuration and index sync
- `--skip-counter`: Skip counter processor sync
- `--skip-backup`: Skip backup of clone server before sync
- `--skip-metadata-blocks`: Skip metadata blocks synchronization
- `--skip-jvm-options`: Skip JVM options synchronization
- `--skip-post-setup`: Skip post-sync setup operations
- `--help`: Display help message

Example: 
```bash
./fetch_prod.sh --dry-run --skip-solr
```

## Step-by-Step Process

### Initialization & Setup

1. **Script Location Detection**: The script determines its own directory to locate the `.env` file.
2. **Environment Loading**: The `.env` file is loaded from the script's directory.
3. **Variable Validation**: Required variables are checked and validated in groups. Database passwords are optional.
4. **Command-Line Parsing**: User-provided flags are processed.
5. **Safety Checks**: 
   - Verifies that the script is not running on the production server by extracting FQDN from domain.xml
   - Prevents accidental restoration to production by validating that DB_HOST is not set to production server
   - Exits with clear error messages if safety checks fail
6. **Disk Space Checks**: Before major file transfers, the script estimates required disk space and aborts if insufficient space is available.
7. **Lock File**: Prevents concurrent runs of the script.

### Pre-Execution

1. **Version Check**: Compares Dataverse versions between production and clone to warn about potential compatibility issues.
2. **Backup Creation** (if not skipped):
   - Creates a timestamped backup directory
   - Backs up the local database (using password if set, otherwise peer/ident auth)
   - Backs up critical configuration files (domain.xml, etc.)
3. **User Confirmation**: Asks for confirmation before proceeding with potentially destructive operations.

### 1. Database Operations

This step handles copying the database from production to the clone server:

1. Creates a database dump on the production server
2. Transfers the dump file to the clone server
3. Modifies domain-specific settings in the dump
4. Restores the database to the clone server (using password if set, otherwise peer/ident auth)
5. Runs post-restore SQL to:
   - Disable DOI registration
   - Set a site notice indicating "THIS IS A TEST INSTANCE"
   - Disable email sending features

The process uses PostgreSQL system authentication by default, but will use passwords if provided in the `.env` file.

### 2. Dataverse Files Operations

This step synchronizes files and configurations:

1. Establishes exclusion patterns for sensitive files:
   - SSL certificates (*.pem, *.key, *.keystore, *.jks, *.cer, *.crt)
   - Configuration secrets (secrets.env, domain.xml, keyfile, password files)
2. Uses `rsync` (with progress reporting) to copy files from production to clone
3. Handles Payara configuration files separately:
   - Copies only essential property files
   - Updates domain-specific references
   - Preserves local security configurations

When `FULL_COPY` is set to "false" in the .env file, the script will limit file sizes to 2MB during transfer, which maintains the directory structure while avoiding transferring large data files. This is useful for testing configurations without requiring excessive disk space or bandwidth. When set to "true" (default), all files (except those excluded) are transferred.

### 3. Solr Operations

This step synchronizes the Solr search engine configuration:

1. Stops the local Solr service
2. Copies Solr configuration files from production
3. Optionally copies Solr indexes (user prompted due to potential large size)
4. Restarts the local Solr service

### 4. Counter Processor Operations

This step handles the COUNTER reporting processor used for statistics. This step is automatically skipped if any of the counter processor variables are not set.

1. Copies the counter processor application from production
2. Updates configuration files to replace production URLs with clone URLs
3. Copies and updates the counter daily script
4. Copies and updates the counter weekly script

The script properly handles root-owned counter scripts by using sudo to read from production and write to the local server when needed.

### 5. Cron Jobs Operations

This step handles scheduled tasks:

1. Fetches the production crontab
2. Modifies paths to match the clone server environment
3. Saves the modified crontab for manual review
4. Does NOT automatically apply the crontab to avoid scheduling conflicts

### 6. Metadata Blocks Operations

This step handles the synchronization of metadata blocks:

1. Waits for Payara to be ready
2. Fetches list of metadata blocks from production
3. Enables each metadata block on the clone using the Dataverse API
4. Verifies block enablement and handles errors gracefully
5. Reports success/failure for each block

Note: This step requires a valid `DATAVERSE_API_KEY` in the `.env` file.

### 7. S3 Configuration

This step manages S3 storage configuration:

1. Detects S3 configuration from production (both database settings and JVM options)
2. Provides interactive options for configuring S3 on the clone:
   - Configure new S3 bucket
   - Switch to local storage
   - Inherit production settings (not recommended)
3. Updates database settings based on user choice
4. Manages JVM options related to S3 configuration
5. Verifies configuration changes

### 8. Post-Sync Operations

This step handles final adjustments:

1. Updates file permissions and ownership
2. Synchronizes JVM options from production:
   - Preserves local S3 configuration
   - Adds missing non-S3 options
   - Handles duplicate options
3. Suggests service restarts as needed
4. Verifies Dataverse is running and accessible

### Summary & Closure

1. Provides a detailed summary of operations performed
2. Lists next steps for verification and finalization
3. Provides rollback instructions if needed
4. Includes troubleshooting hints for common issues

## What Gets Preserved

The script carefully preserves the following items on the clone server:

- SSL certificates and private keys
- Domain-specific configuration in Payara domain.xml
- Secret keys and credentials
- Solr security configurations
- Local .env file

## Progress Reporting & Resilience

- All major file transfers use a custom progress-reporting wrapper for `rsync`, showing percentage complete and elapsed time.
- The script checks for sufficient disk space before large transfers and aborts if not enough is available.
- Ownership and permissions are restored even if the script exits early due to an error.
- A lock file prevents concurrent runs.

## Troubleshooting

If you encounter issues after running the script:

- Check logs in the Payara domains directory
- Verify Solr service status using `systemctl status solr`
- Test database connectivity with `psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c 'SELECT 1'`
- Review backed up files in the automatically created backup directory
- Consult the script's log file (`fetching_prod_backup.log`)

If the script reports "DB_HOST points to production" error, edit your .env file to change DB_HOST from the production domain to localhost or your local database server.

## Rollback Procedure

If necessary, you can roll back using the backup created before sync:

1. Restore the database: `psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $BACKUP_DIR/database_backup.sql`
2. Restore configuration files from the backup directory
3. Restart services as needed

## Security Considerations

- The script actively avoids transferring security credentials
- Production database credentials are only used on the production server if set
- Local authentication mechanisms are used for database operations on the clone (passwords are optional)
- Security-sensitive files are explicitly excluded from transfer



In other scripts like @upgrade_6_1_to_6_2.sh  it breaks the script into functions and steps through the main function making maintainence on ths script simpler. Can you take a look at how that script structures steps and replicate it the fetch prod script in efforts to clean up but not remove any functionality.

