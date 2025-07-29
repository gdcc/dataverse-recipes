# Dataverse 6.5 to 6.6 Upgrade Guide

## Overview

This document explains the Dataverse 6.5 to 6.6 upgrade process, what to expect during the upgrade, and how to verify that your upgrade completed successfully.

## 🔄 Understanding the Upgrade Process

### Expected Behavior During Deployment

**❗ IMPORTANT: SQL Errors During Deployment Are NORMAL**

During the upgrade, you will see many SQL errors like:
```
ERROR: relation "externaltooltype" already exists
ERROR: constraint "fk_externaltooltype_externaltool_id" already exists
```

**These errors are EXPECTED and NORMAL** during Dataverse upgrades because:
1. The database schema is partially updated during the upgrade process
2. The new WAR file attempts to create database objects that already exist
3. The upgrade script automatically handles these conflicts

### Automatic Recovery Process

When the script detects these expected database schema conflicts, it:
1. 📊 Analyzes the deployment output to classify errors as benign vs. critical
2. 🔄 Stops Payara service
3. 🧹 Cleans cached application files
4. 🚀 Restarts Payara service
5. ✅ Retries deployment (which then succeeds)

## 📋 What Gets Upgraded

### Component Versions
- **Payara**: Upgraded to 6.2025.2
- **Dataverse Application**: Upgraded to 6.6
- **Solr Configuration**: Updated with performance optimizations
- **Database Schema**: Automatically migrated to 6.6 structure

### New Features in 6.6
- **3D Objects Metadata Block**: Support for 3D object files
- **Enhanced Search**: Range search capabilities for dates and numbers
- **Performance Improvements**: Optimized Solr commit timing settings
- **Security Updates**: Enhanced security policies

### Solr Performance Optimizations

Based on forum feedback, the upgrade applies these Solr configuration changes:
- `autoCommit.maxTime`: Changed from 15000ms to 30000ms
- `autoSoftCommit.maxTime`: Changed from -1 (disabled) to 1000ms

These changes improve performance and reduce I/O overhead.

## ✅ Verifying Your Upgrade

### Automated Verification

Run the verification script:
```bash
./shell/upgrades/verify_6_6_upgrade.sh
```

This script checks:
- ✅ Core services (Payara, Solr, PostgreSQL) are running
- ✅ Dataverse API is accessible and reports version 6.6
- ✅ Search index is functional
- ✅ New 6.6 features are available
- ✅ Overall system health

### Manual Verification Steps

1. **Check Version**:
   ```bash
   curl -s "http://localhost:8080/api/info/version" | jq '.data.version'
   ```
   Should return: `"6.6"`

2. **Test Web Interface**:
   - Browse to http://localhost:8080
   - Log in as an admin user
   - Create a test dataset
   - Upload a test file

3. **Verify Search**:
   - Use the search box on the main page
   - Verify results appear correctly
   - Test faceted search functionality

4. **Check New Metadata Block**:
   ```bash
   curl -s "http://localhost:8080/api/metadatablocks" | jq '.data[].name' | grep -i "3d"
   ```

## 🚨 Troubleshooting

### If the Upgrade Failed

1. **Check Service Status**:
   ```bash
   systemctl status payara solr postgresql
   ```

2. **Review Logs**:
   ```bash
   # Upgrade log
   tail -100 shell/upgrades/dataverse_upgrade_6_5_to_6_6.log
   
   # Payara logs
   tail -100 /usr/local/payara6/glassfish/domains/domain1/logs/server.log
   
   # System logs
   journalctl -u payara -u solr --since "1 hour ago"
   ```

3. **Check Database Connectivity**:
   ```bash
   sudo -u postgres psql -d dataverse -c "SELECT version();"
   ```

### Common Issues and Solutions

#### Issue: Payara Won't Start
- **Cause**: Java version incompatibility or memory issues
- **Solution**: Check Java version (should be 11+) and available memory

#### Issue: Search Not Working
- **Cause**: Solr indexing in progress or configuration issues
- **Solution**: Wait for indexing to complete, check Solr status

#### Issue: Database Connection Errors
- **Cause**: PostgreSQL service issues or connection limits
- **Solution**: Restart PostgreSQL, check connection settings

## 📊 Expected Timeline

| Phase | Duration | Description |
|-------|----------|-------------|
| Pre-flight checks | 1-2 minutes | Validate system state |
| Payara upgrade | 2-3 minutes | Download and install new version |
| Initial deployment | 5-10 minutes | Deploy WAR (with expected SQL errors) |
| Recovery & retry | 3-5 minutes | Automatic error recovery |
| Post-deployment | 10-15 minutes | Metadata blocks, indexing, restart |
| **Total** | **20-35 minutes** | Complete upgrade process |

## 🔍 Log Analysis

### What to Look for in Logs

**✅ Success Indicators**:
```
✅ Step 'deploy' marked as complete
✅ Retry deployment completed successfully!
Citation metadata block loaded successfully
✅ UPGRADE SUMMARY COMPLETE
```

**⚠️ Expected Warnings**:
```
INFO: Ignoring benign SQL error: relation "xyz" already exists
INFO: Found migration-related error pattern (may be temporary)
WARNING: Found non-benign error: PER01003: Deployment encountered SQL Exceptions
```

**❌ Actual Problems**:
```
ERROR: OutOfMemoryError
ERROR: Unable to connect to database
ERROR: Permission denied
ERROR: No space left on device
```

## 🛡️ Rollback Procedure

If you need to rollback:

1. **Stop Services**:
   ```bash
   sudo systemctl stop payara
   ```

2. **Restore Payara**:
   ```bash
   sudo rm -rf /usr/local/payara6
   sudo mv /usr/local/payara6.6.5.backup /usr/local/payara6
   ```

3. **Restore Database** (if you created a backup):
   ```bash
   sudo -u postgres psql -d dataverse < dataverse_backup.sql
   ```

4. **Restart Services**:
   ```bash
   sudo systemctl start payara
   ```

## 📞 Getting Help

If you encounter issues:

1. **Run the verification script** to get a system health report
2. **Check the troubleshooting section** above
3. **Review log files** for specific error messages
4. **Contact your Dataverse support team** with:
   - The upgrade log file
   - Output from the verification script
   - Any specific error messages

## 🎉 Success!

If your verification script shows all green checkmarks, congratulations! Your Dataverse 6.6 upgrade is complete.

**Next steps**:
- Test your critical workflows
- Update any external integrations
- Monitor the system for the first few days
- Consider updating your backup procedures for the new version

---

*This upgrade script was designed to handle the complexities of Dataverse upgrades while providing clear feedback about what's happening at each step.* 


The script will need to exit appropriately when things go wrong and tolerate environmental irregularities while maintaining upgrade integrity. It needs to be ready for immediate deployment across multiple Dataverse 6.5 installations. All of this means it needs to run without errors and there seems to be errors in the log file @dataverse_upgrade_6_5_to_6_6.log 
After we fix these issues I'm going to reset the virtual machine this is running on and try this script again. So any of those local changes you just made will be lost so make sure you're doing it in this script. 