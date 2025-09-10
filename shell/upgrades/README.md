# Dataverse Upgrade Scripts

This directory contains scripts for upgrading Dataverse installations between different versions.

## Available Upgrade Scripts

- `upgrade_5_14_to_6_0.sh` - Upgrades Dataverse from version 5.14 to 6.0
- `upgrade_6_0_to_6_1.sh` - Upgrades Dataverse from version 6.0 to 6.1
- `upgrade_6_1_to_6_2.sh` - Upgrades Dataverse from version 6.1 to 6.2
- `upgrade_6_2_to_6_3.sh` - Upgrades Dataverse from version 6.2 to 6.3
- `upgrade_6_2_extras.sh` - Additional upgrade steps for 6.2 to 6.3 transition
- `upgrade_6_3_to_6_4.sh` - Upgrades Dataverse from version 6.3 to 6.4
- `upgrade_6_4_to_6_5.sh` - Upgrades Dataverse from version 6.4 to 6.5
- `upgrade_6_5_to_6_6.sh` - Upgrades Dataverse from version 6.5 to [6.6](6.6%20Release%20Notes.md)
- `upgrade_exporter_croissant.sh` - Adds Croissant exporter functionality
- `upgrade_java.sh` - Upgrades Java version for Dataverse

## Prerequisites

1. Required system commands:
   ```bash
   # On Debian/Ubuntu:
   sudo apt-get install curl wget git jq

   # On RHEL/CentOS:
   sudo yum install curl wget git jq
   ```

2. Proper permissions:
   - Read/write access to Dataverse installation directory
   - Database access credentials
   - Application server restart privileges

3. Configuration:
   - Backup of current Dataverse installation
   - Database backup
   - Environment-specific configuration files

## Usage

1. Backup your system:
   ```bash
   # Backup database
   pg_dumpall > dataverse_backup_$(date +%Y%m%d_%H%M%S).sql
   
   # Backup application files
   tar -czf dataverse_app_backup_$(date +%Y%m%d_%H%M%S).tar.gz /path/to/dataverse
   ```

2. Run the appropriate upgrade script:
   ```bash
   # For version-specific upgrades
   ./upgrade_X_Y_to_Z_W.sh
   
   # For additional components
   ./upgrade_exporter_croissant.sh
   ./upgrade_java.sh
   ```

3. Monitoring instructions:
   - Check application server logs for errors
   - Verify database connectivity
   - Test core Dataverse functionality
   - Monitor system resources during upgrade

## Dynamic Configuration

The upgrade scripts support dynamic configuration of software metadata fields through environment variables. This makes the scripts more flexible and production-ready.

### How to Use

**Option 1: Use the helper script (recommended):**
```bash
./generate_env.sh
nano .env  # Edit the configuration
./upgrade_X_Y_to_Z_W.sh
```

**Option 2: Manual setup:**
```bash
cp sample.env .env
nano .env  # Edit the configuration
./upgrade_X_Y_to_Z_W.sh
```

**Option 3: Use defaults (no .env file):**
```bash
./upgrade_X_Y_to_Z_W.sh  # Uses default values
```

### Configuration Options

Each software metadata field can be configured with one of these values:

- `true` - Field will be added as multi-valued (can contain multiple values)
- `false` - Field will be added as single-valued (can contain only one value)
- `disabled` - Field will be skipped entirely (not added to schema)

### Example Customizations

**Make swLicense multi-valued instead of single-valued:**
```bash
SOFTWARE_FIELD_SWLICENSE=true
```

**Disable a field entirely:**
```bash
SOFTWARE_FIELD_SWVERSION=disabled
```

**Change a multi-valued field to single-valued:**
```bash
SOFTWARE_FIELD_SWCONTRIBUTORNAME=false
```

### Fallback Behavior

If no `.env` file exists, the scripts will use the default values that match the original Dataverse specification. This ensures backward compatibility.

## Troubleshooting

Common issues and solutions:

1. Database connection issues:
   - Check database service status
   - Verify connection credentials
   - Ensure database user has required permissions

2. Application server issues:
   - Check server logs for errors
   - Verify Java version compatibility
   - Ensure sufficient memory allocation

3. Schema update failures:
   - Check database backup integrity
   - Verify schema modification permissions
   - Review error logs for specific field conflicts

## Rollback

If the upgrade fails:

1. Database rollback:
   ```bash
   # Restore from backup
   psql -f dataverse_backup_YYYYMMDD_HHMMSS.sql
   ```

2. Application rollback:
   ```bash
   # Restore application files
   tar -xzf dataverse_app_backup_YYYYMMDD_HHMMSS.tar.gz -C /
   ```

3. Configuration rollback:
   ```bash
   # Restore original configuration files
   cp backup/config/* /path/to/dataverse/config/
   ```

## Testing & Verification

### Version Verification
- **Implementation**: Each upgrade script includes version checking
- **Components Checked**:
  - Dataverse application version
  - Database schema version
  - Java version compatibility
  - Application server version

### Performance Monitoring
- **Implementation**: Built-in performance checks in upgrade scripts
- **Threshold**: Configurable based on environment
- **Check Interval**: Continuous monitoring during upgrade process

## Contributing

1. Fork the repository
2. Create a feature branch for your upgrade script
3. Follow the established upgrade script pattern
4. Include comprehensive testing and verification
5. Submit a pull request with detailed documentation

## Security Note

The `.env` file contains configuration only and no sensitive data. However, ensure proper file permissions:

```bash
chmod 600 .env
```

This prevents other users from reading your configuration.

## Additional Resources

- [Dataverse Upgrade Script Pattern](Dataverse_Upgrade_Script_Pattern.md)
- [Upgrade Documentation Style Guide](UPGRADE_DOCUMENTATION_STYLE.md)
- [6.6 Release Notes](6.6%20Release%20Notes.md)
- [Solr Schema Fix Summary](SOLR_SCHEMA_FIX_SUMMARY.md) 