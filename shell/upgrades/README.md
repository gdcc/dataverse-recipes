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

## License

This project is licensed under the MIT License - see the LICENSE file for details. 