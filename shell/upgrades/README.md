# Dataverse Upgrade Scripts

This directory contains scripts for upgrading Dataverse installations between different versions.

## Available Upgrade Scripts

- `upgrade-5-14-to-6-0.sh` - Upgrades Dataverse from version 5.14 to [6.0](https://github.com/IQSS/dataverse/releases/tag/v6.0)
- `upgrade-6-0-to-6-1.sh` - Upgrades Dataverse from version 6.0 to [6.1](https://github.com/IQSS/dataverse/releases/tag/v6.1)
- `upgrade-6-1-to-6-2.sh` - Upgrades Dataverse from version 6.1 to [6.2](https://github.com/IQSS/dataverse/releases/tag/v6.2)
- `upgrade-6-2-extras.sh` - Additional configurations for Dataverse 6.2
- `upgrade-java.sh` - Companion script for upgrading Java

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

# Dataverse 6.0 Upgrade Implementation Notes

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