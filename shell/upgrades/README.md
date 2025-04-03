# Dataverse Upgrade Scripts

This directory contains scripts for upgrading Dataverse installations between different versions.

## Available Upgrade Scripts

- `upgrade-5-14-to-6-0.sh` - Upgrades Dataverse from version 5.14 to [6.0](https://github.com/IQSS/dataverse/releases/tag/v6.0)
- `upgrade-6-0-to-6-1.sh` - Upgrades Dataverse from version 6.0 to [6.1](https://github.com/IQSS/dataverse/releases/tag/v6.1)
- `upgrade-6-1-to-6-2.sh` - Upgrades Dataverse from version 6.1 to [6.2](https://github.com/IQSS/dataverse/releases/tag/v6.2)
- `upgrade-6-2-extras.sh` - Additional configurations for Dataverse 6.2
- `upgrade-java.sh` - Companion script for upgrading Java
- `upgrade-exporter-croissant.sh` - Reinstalls and configures the Croissant metadata exporter

## Prerequisites

Before running any upgrade script, ensure you have:

1. Required system commands:
   ```bash
   # On Debian/Ubuntu:
   sudo apt-get install sed awk grep find tar unzip rsync curl wget procps systemd jq bc ed procps

   # On RHEL/CentOS:
   sudo yum install sed awk grep find tar unzip rsync curl wget procps systemd jq bc ed procps-ng
   ```

2. Proper permissions:
   - The script should be run as a non-root user with sudo privileges
   - The user should have access to the Dataverse and Solr service files

3. Configuration:
   - Copy `sample.env` to `.env` in the same directory
   - Update the `.env` file with your system-specific values

## Usage

1. Backup your system:
   ```bash
   # Backup your database
   pg_dump -U dataverse dataverse > dataverse_backup.sql

   # Backup your configuration files
   sudo tar -czf dataverse_config_backup.tar.gz /usr/local/payara5 /usr/local/solr
   ```

2. Run the appropriate upgrade script:
   ```bash
   ./upgrade-5-14-to-6-0.sh
   ```

3. Monitor the upgrade process:
   - The script will display progress and any errors
   - Check the logs in `/usr/local/payara6/glassfish/domains/domain1/logs/`
   - Monitor system resources using the built-in CPU monitoring

## Troubleshooting

Common issues and solutions:

1. If the script fails during Payara upgrade:
   - Check Payara logs in `/usr/local/payara6/glassfish/domains/domain1/logs/`
   - Verify Java version compatibility
   - Ensure sufficient disk space

2. If Solr upgrade fails:
   - Check Solr logs in `/usr/local/solr/server/logs/`
   - Verify Solr service status with `systemctl status solr`
   - Ensure proper permissions on Solr directories

3. If Dataverse deployment fails:
   - Check application logs in Payara
   - Verify database connectivity
   - Ensure all required environment variables are set

## Rollback

If the upgrade fails, you can rollback using your backups:

1. Restore the database:
   ```bash
   psql -U dataverse dataverse < dataverse_backup.sql
   ```

2. Restore configuration files:
   ```bash
   sudo tar -xzf dataverse_config_backup.tar.gz -C /
   ```

3. Restart services:
   ```bash
   sudo systemctl restart payara
   sudo systemctl restart solr
   ```

## Contributing

If you find issues or have improvements:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

# Dataverse 6.0 Upgrade Implementation Notes (from 5.14)

## Component Upgrades

### Java 17 Upgrade
- **Release Note**: Required Java upgrade from version 11 to 17
- **Implementation**: `upgrade_java()` [Line 234]
- **Verification**: `verify_versions()` [Line 1089]
```bash
# Checks Java version and updates system default
java -version 2>&1 | grep "version" | grep "17"
```

### Payara 6.2023.8 Upgrade
- **Release Note**: Required upgrade from Payara 5
- **Implementation**: Multiple functions
  - `download_payara()` [Line 456] - Downloads new version
  - `install_payara()` [Line 467] - Installs and configures
  - `migrate_domain_xml()` [Line 489] - Migrates configurations
- **Verification**: `verify_versions()` [Line 1089]
```bash
"$PAYARA_NEW/bin/asadmin" version | grep "6.2023.8"
```

### Solr 9.3.0 Upgrade
- **Release Note**: Required upgrade from Solr 8
- **Implementation**: Multiple functions
  - `upgrade_solr()` [Line 890] - Core upgrade process
  - `update_solr_configs()` [Line 923] - Configuration updates
  - `update_solr_schema()` [Line 978] - Schema migration
- **Verification**: `verify_versions()` [Line 1089]
```bash
curl -s "http://localhost:8983/solr/admin/info/system" | grep "solr-spec-version"
```

## Breaking Changes

### Custom Metadata Blocks
- **Release Note**: Warning about custom metadata block compatibility
- **Implementation**: `check_custom_metadata()` [Line 1002]
- **Documentation**: [Updating the Solr Schema](https://guides.dataverse.org/en/6.0/admin/metadatacustomization.html#updating-the-solr-schema)

## Migration Steps

### Configuration Migration
1. **Domain.xml**
   - **Implementation**: `migrate_domain_xml()` [Line 489]
   - **Verification**: Configuration check in startup logs

2. **JHOVE Configuration**
   - **Implementation**: `migrate_jhove_files()` [Line 567]
   - **Files Affected**: 
     - jhove.conf
     - jhoveConfig.xsd

3. **Logo Migration**
   - **Implementation**: `migrate_logos()` [Line 578]
   - **Path**: `/usr/local/payara6/glassfish/domains/domain1/docroot/logos`

## Known Issues

### Archiver Compatibility
- **Release Note**: Potential incompatibilities with Google Cloud and DuraCloud archivers
- **Status**: Not implemented in script
- **Required Action**: Manual testing needed if using these archivers

## Testing & Verification

### Version Verification
- **Implementation**: `verify_versions()` [Line 1089]
- **Components Checked**:
  - Java 17
  - Payara 6.2023.8
  - Solr 9.3.0
  - Dataverse 6.0

### Performance Monitoring
- **Implementation**: `monitor_cpu()` [Line 1056]
- **Threshold**: ${CPU_THRESHOLD}%
- **Check Interval**: ${CHECK_INTERVAL} seconds 

# Dataverse 6.1 Upgrade Implementation Notes (from 6.0)
# Add notes here

# Replace with proper content
## Component Upgrades

### Dataverse 6.1 WAR Deployment
- **Release Note**: Upgrade to Dataverse 6.1
- **Implementation**: Multiple functions
  - `download_war_file()` [Line 183] - Downloads and verifies WAR file
  - `deploy_new_version()` [Line 346] - Deploys the new version
- **Verification**: 
```bash
curl -s "http://localhost:8080/api/info/version" | grep -q "6.1"
```

### Metadata Block Updates
- **Release Note**: Required updates to metadata blocks
- **Implementation**: Multiple functions
  - `download_metadata_file()` [Line 193] - Downloads metadata files
  - `update_metadata_block()` [Line 213] - Updates metadata blocks
- **Files Updated**:
  - Geospatial metadata block
  - Citation metadata block

### Solr Schema Updates
- **Release Note**: Solr schema compatibility updates
- **Implementation**: Multiple functions
  - `download_solr_schema_updater()` [Line 229] - Downloads schema updater
  - `update_solr_schema()` [Line 243] - Updates Solr schema
- **Verification**: 
```bash
curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" | grep -q "true"
```

## Migration Steps

### Environment Configuration
1. **Payara Environment Variables**
   - **Implementation**: Setting PAYARA environment variable in .bashrc
   - **Files Affected**: 
     - User's .bashrc file

### Service Management
1. **Controlled Restart Sequence**
   - **Implementation**: Multiple functions
     - `stop_payara()` [Line 125]
     - `start_payara()` [Line 149]
     - `stop_solr()` [Line 135]
     - `start_solr()` [Line 144]

### Documentation Migration
1. **Metadata Re-export**
   - **Implementation**: `export_all_metadata()` [Line 355]
   - **Verification**: API endpoint health check

## Additional Components

### ImageMagick Integration
- **Release Note**: Added support for ImageMagick
- **Implementation**: Optional installation and configuration
- **Verification**: 
```bash
convert -version
```
- **Configuration**: Added JVM option for convert.path

# Dataverse 6.2 Upgrade Implementation Notes (from 6.1)

## Component Upgrades

### Dataverse 6.2 WAR Deployment
- **Release Note**: Upgrade to Dataverse 6.2
- **Implementation**: Multiple functions
  - `download_war_file()` [Line 89] - Downloads and verifies WAR file
  - `deploy_new_version()` [Line 488] - Deploys the new version
- **Verification**: 
```bash
curl -s "http://localhost:8080/api/info/version" | grep -q "6.2"
```

### Solr Schema Updates
- **Release Note**: Required updates to Solr schema
- **Implementation**: Multiple functions
  - `download_solr_schema_file()` [Line 115] - Downloads schema file
  - `update_solr_schema_file()` [Line 126] - Updates Solr schema
  - `download_solr_schema_updater()` [Line 373] - Downloads schema updater
  - `update_solr_schema_updater()` [Line 390] - Updates with custom fields
- **Verification**: 
```bash
grep -q 'license' /usr/local/solr/server/solr/collection1/conf/schema.xml
```

### Metadata Block Updates
- **Release Note**: Comprehensive updates to metadata blocks
- **Implementation**: Multiple functions for each metadata block
  - Citation, Geospatial, Astrophysics, and Biomedical metadata blocks
- **Files Updated**:
  - `/tmp/citation.tsv`
  - `/tmp/geospatial.tsv`
  - `/tmp/astrophysics.tsv`
  - `/tmp/biomedical.tsv`

## Migration Steps

### Configuration Migration
1. **Permalink Configuration**
   - **Implementation**: `update_set_permalink()` [Line 528]
   - **Settings Modified**:
     - dataverse.pid.perma1.* JVM options
     - dataverse.pid.providers and default provider

2. **Rate Limiting Configuration**
   - **Implementation**: `set_rate_limit()` [Line 514]
   - **Files Affected**: 
     - rate-limit-actions-setting.json
   - **API Endpoint**: `/api/admin/settings/:RateLimitingCapacityByTierAndAction`

3. **Dataset Page Fix**
   - **Implementation**: `replace_doi_with_DOI()` [Line 554]
   - **Files Affected**:
     - dataset.xhtml
   - **Change**: Fix for Make Data Count display

## Testing & Verification

### Solr Indexing Status
- **Implementation**: `status_solr()` [Line 466]
- **Components Checked**:
  - Solr core status
  - Index current state
  - Document count
- **Verification**:
```bash
curl -s "http://localhost:8983/solr/admin/cores?action=STATUS" | jq
```

### Service Availability
- **Implementation**: `wait_for_site()` [Line 454]
- **Components Checked**:
  - HTTP response code
  - Site accessibility
- **Threshold**: HTTP 200 response
- **Check Interval**: 1 second

### Re-indexing Process
- **Implementation**: `reindex_solr()` [Line 501]
- **Components Checked**:
  - Index timestamps
  - Index status
- **Verification**:
```bash
curl -s "http://localhost:8080/api/admin/index/status"
```

## Component Upgrades

### Croissant Metadata Exporter
- **Version**: Configurable via CROISSANT_VERSION in .env (default: 0.1.3)
- **Implementation**: Multiple functions
  - `enable_croissant()` [Line 92] - Installs and configures exporter
  - `re_export_metadata()` [Line 116] - Re-exports all metadata
- **Verification**: 
```bash
curl -s "http://localhost:8080/api/admin/metadata" | grep -q "croissant"
```

## Migration Steps

### Configuration Migration
1. **JVM Options**
   - **Implementation**: `set_jvm_option()` [Line 65]
   - **Files Affected**: 
     - Payara JVM options
   - **Settings Modified**:
     - dataverse.exporter.metadata.croissant.enabled
     - dataverse.spi.exporters.directory

2. **JAR File Installation**
   - **Implementation**: `enable_croissant()` [Line 92]
   - **Path**: Configurable via METADATA_JAR_FILE_DIRECTORY in .env

## Testing & Verification

### Exporter Operation
- **Implementation**: `re_export_metadata()` [Line 116]
- **Components Checked**:
  - Metadata exporter API endpoint
  - Croissant JAR file installation
  - JVM configuration settings 