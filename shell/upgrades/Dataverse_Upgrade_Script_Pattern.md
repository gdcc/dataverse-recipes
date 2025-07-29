# Dataverse Upgrade Script Pattern
## Core Upgrade Pattern (Universal Steps)

Every Dataverse upgrade follows this fundamental sequence:

### 1. Pre-Upgrade Validation
- Check current version matches expected version
- Validate environment variables (.env file)
- Check required system commands
- Verify disk space and system resources
- **CRITICAL: Check and upgrade Java BEFORE any asadmin commands**

### 2. Java Prerequisites (Learned from 6.5→6.6)
```bash
# MUST happen before any Payara/asadmin operations
1. Check current Java version
2. Upgrade Java if needed (especially for Payara 6+ requiring Java 11+)
3. Verify Java upgrade completed successfully
4. ONLY THEN proceed with Payara commands
```

**Why**: Payara 6.x requires Java 11+, but the old Payara installation may try to run with Java 8, causing "UnsupportedClassVersionError". Java must be upgraded before any `asadmin` commands are executed.

### 3. Application Lifecycle Management
```bash
# Standard sequence for ALL upgrades:
1. Check for mixed state issues and resolve
2. Undeploy current Dataverse version
3. Stop Payara application server
4. Stop Solr search engine (if schema updates needed)
5. Download new WAR file (with hash verification)
6. Deploy new WAR file to Payara
7. Start services (Payara, then conditionally Solr)
8. Wait for site availability and API accessibility
```

### 4. Post-Deployment Verification
- Check deployed version via API
- Verify services are responding correctly
- Verify database migrations completed

## Critical Implementation Details (Lessons Learned)

### Mixed State Detection and Resolution
Upgrades can fail if the system is in a mixed state (partially upgraded). Scripts must:
- Detect version mismatches between deployed apps and API responses
- Clean up any partial deployments
- Reset caches and temporary files
- Ensure clean deployment state

### Solr Schema Updates - Critical Requirements
**IMPORTANT**: When updating Solr schema with `update-fields.sh`:

```bash
# REQUIRED sequence for schema updates:
1. Ensure Dataverse API is accessible and responding
2. STOP Solr service completely
3. Verify no Solr processes are running (force kill if needed)
4. Backup existing schema.xml
5. Run update-fields.sh with Solr STOPPED
6. Validate updated schema.xml (XML validation)
7. Start Solr service
8. Wait for Solr to be ready before proceeding
```

**Why**: The `update-fields.sh` script expects to modify schema files while Solr is not running. Running it with Solr active causes failures.

### Enhanced Error Handling Patterns

#### Deployment Error Analysis
Not all deployment "errors" are fatal:
```bash
# Benign errors (can be ignored):
- "duplicate key value violates unique constraint"
- "relation already exists" 
- "application already registered"
- Database migration related errors (temporary during deployment)

# Fatal errors (must stop upgrade):
- "connection refused"
- "authentication failed"
- "disk full"
- "syntax error"
```

#### Recovery Mechanisms
Scripts should include:
- Automatic retry with cache clearing
- Backup restoration capabilities
- Component-specific diagnostics
- Rollback procedures for catastrophic failures

### API Accessibility Verification
Before any API-dependent operations:
```bash
# Wait for API to be accessible with timeout
while [ $counter -lt $timeout ]; do
    if curl -s --fail "http://localhost:8080/api/info/version" > /dev/null 2>&1; then
        api_ready=true
        break
    fi
    sleep 5
    counter=$((counter + 5))
done
```

## Version-Specific Variations

### Major Infrastructure Changes (5.14 → 6.0)
This was a **major upgrade** requiring infrastructure changes:
- **Java upgrade** (Java 8 → Java 17)
- **Payara upgrade** (Payara 5 → Payara 6) 
- **Solr upgrade** (Solr 8 → Solr 9.3.0)
- **Complete service migration** (moving from old to new versions)
- **Configuration migration** (domain.xml, service files, paths)

### Minor Version Updates (6.0 → 6.1, 6.1 → 6.2, 6.5 → 6.6)
These follow the **standard pattern** with specific additions:

#### Common Extras for Minor Versions:
1. **Metadata block updates** (.tsv files)
   - Citation metadata block
   - Geospatial metadata block  
   - Domain-specific blocks (astrophysics, biomedical, 3d_objects)

2. **Solr schema updates**
   - Download new schema.xml or update-fields.sh
   - Update field definitions for custom metadata blocks
   - Reindex if needed

3. **Configuration updates**
   - New JVM options
   - Feature toggles/settings
   - Security configurations (SameSite cookies)
   - Bug fixes (like the DOI→DOI text replacement)

### Infrastructure Updates (6.5 → 6.6)
This upgrade included significant infrastructure changes despite being a "minor" version:
- **Java 8 → Java 11** requirement
- **Payara 5 → Payara 6.2025.2** upgrade
- **Solr 8.11 → Solr 9.8.0** upgrade
- **Custom metadata field schema updates**
- **New metadata blocks** (3D Objects)

## Script Structure Evolution

### 5.14 → 6.0 (Complex Migration)
- 22 main steps + Solr substeps
- Infrastructure component replacement
- Service file updates
- Path migrations

### 6.0 → 6.1 (Standard Minor Upgrade)
- 8 main steps
- Focus on metadata blocks
- Solr schema update
- Simple WAR deployment

### 6.1 → 6.2 (Standard + Enhancements)
- 9 main steps + additional configuration
- Multiple metadata blocks
- Rate limiting configuration
- Permalink configuration
- Bug fixes

### 6.5 → 6.6 (Infrastructure + Content Updates)
- 21 main steps with enhanced error handling
- Java/Payara/Solr upgrades
- Mixed state resolution
- **Dynamic configuration system** for metadata fields
- **Comprehensive schema field management** with validation
- **Production-ready configuration** with environment variables
- **Helper scripts** for easy setup and maintenance
- Comprehensive backup and recovery

## Best Practices for Future Scripts

### 1. Always Include
- Java version checking before any asadmin commands
- Mixed state detection and resolution
- Comprehensive error analysis (benign vs fatal)
- Component-specific recovery mechanisms
- API accessibility verification
- Backup and validation steps
- **Dynamic configuration support** (environment variables)
- **Schema field validation** for custom metadata blocks

### 2. Step Ordering Guidelines
```bash
1. Environment validation
2. Java upgrade (if needed)
3. Version checking and mixed state resolution
4. Service lifecycle management
5. Component upgrades (infrastructure first)
6. Application deployment
7. Configuration updates
8. Content updates (metadata blocks, schema)
9. Post-deployment operations (reindex, export)
10. Final verification
```

### 3. Error Handling Standards
- Use temporary files for output analysis
- Implement retry mechanisms with exponential backoff
- Include diagnostic information in logs
- Provide clear recovery instructions
- Test rollback procedures
- **Validate configuration values** before applying them
- **Handle schema field conflicts** gracefully

### 4. Validation Requirements
- Hash verification for all downloads
- XML validation for configuration files
- API response validation
- Service health checks
- Version confirmation at each step
- **Environment variable validation** (type checking, value ranges)
- **Schema field completeness** verification

## Dynamic Configuration Patterns (Learned from 6.5→6.6)

### Environment-Based Configuration
For upgrades that require extensive customization (like metadata field configurations):

#### 1. Configuration File Structure
```bash
# Use .env files for dynamic configuration
# Provide example files (env.example) with defaults
# Support fallback to hardcoded defaults if no .env exists
# Validate all configuration values before use
```

#### 2. Configuration Validation
```bash
# Validate environment variable values
for field in "${!config_array[@]}"; do
    local value="${config_array[$field]}"
    if [ "$value" != "true" ] && [ "$value" != "false" ] && [ "$value" != "disabled" ]; then
        log "⚠️  WARNING: Invalid value '$value' for $field, using default"
        config_array["$field"]="default_value"
    fi
done
```

#### 3. Helper Scripts
- Provide `generate_env.sh` for easy setup
- Include comprehensive documentation
- Support multiple configuration options (true/false/disabled)
- Maintain backward compatibility

### Schema Field Management Patterns
When dealing with custom metadata fields that need schema updates:

#### 1. Field Definition Arrays
```bash
# Use associative arrays for field definitions
declare -A software_fields=(
    ["fieldName"]="${ENV_VAR:-default_value}"
)

# Support multiple field types
# - true: multi-valued field
# - false: single-valued field  
# - disabled: skip field entirely
```

#### 2. Schema Update Process
```bash
# 1. Check which fields exist in schema
# 2. Validate field configurations
# 3. Add missing fields with correct properties
# 4. Skip disabled fields
# 5. Log all changes for audit trail
```

#### 3. Error Handling for Schema Updates
- Handle "unknown field" errors during indexing
- Handle "multiple values for non-multiValued field" errors
- Provide clear error messages with field names
- Support iterative fixes for complex schema issues

## Lessons Learned from 6.5→6.6 Upgrade

### Critical Challenges and Solutions

#### 1. Software Metadata Fields Schema Issues
**Problem**: The upgrade introduced 22 new software metadata fields that needed to be added to Solr schema, but the initial implementation was incomplete and caused indexing failures.

**Solution Pattern**:
```bash
# 1. Comprehensive field definition
declare -A software_fields=(
    ["swDependencyDescription"]="${SOFTWARE_FIELD_SWDEPENDENCYDESCRIPTION:-true}"
    # ... all 22 fields with environment variable fallbacks
)

# 2. Validation before application
for field in "${!software_fields[@]}"; do
    local value="${software_fields[$field]}"
    if [ "$value" != "true" ] && [ "$value" != "false" ] && [ "$value" != "disabled" ]; then
        log "⚠️  WARNING: Invalid value '$value' for $field, using default 'false'"
        software_fields["$field"]="false"
    fi
done

# 3. Conditional field addition
for field in "${!software_fields[@]}"; do
    if [ "${field_exists[$field]}" -eq 0 ]; then
        local multi_valued="${software_fields[$field]}"
        
        # Skip disabled fields
        if [ "$multi_valued" = "disabled" ]; then
            log "  ⏭️  Skipping $field field (disabled in .env)"
            continue
        fi
        
        # Add field with correct properties
        sudo sed -i "${insert_line}i\  <field name=\"$field\" type=\"text_general\" indexed=\"true\" stored=\"true\" multiValued=\"$multi_valued\"/>" "$schema_file"
    fi
done
```

#### 2. Iterative Problem Solving
**Problem**: Schema errors appeared one by one during reindexing, requiring multiple iterations to identify all missing fields.

**Solution Pattern**:
- Create temporary diagnostic scripts for rapid testing
- Use comprehensive field lists based on release notes
- Implement proper error handling and logging
- Provide clear feedback about which fields are being processed

#### 3. Production-Ready Configuration
**Problem**: Hardcoded field configurations made the script inflexible for different environments.

**Solution Pattern**:
- Environment variable-based configuration with `.env` files
- Fallback to sensible defaults
- Validation of all configuration values
- Helper scripts for easy setup
- Comprehensive documentation

### Key Improvements for Future Scripts

#### 1. Schema Field Management
- **Always** check release notes for new metadata fields
- **Always** provide configuration options for field properties
- **Always** validate field configurations before applying
- **Always** support disabling fields for environments that don't need them

#### 2. Error Handling
- **Always** provide clear error messages with field names
- **Always** log all schema changes for audit trails
- **Always** support iterative fixes for complex issues
- **Always** validate configurations before applying them

#### 3. Configuration Management
- **Always** use environment variables for customizable settings
- **Always** provide example configuration files
- **Always** include helper scripts for easy setup
- **Always** maintain backward compatibility

## Template for Future Upgrades

Based on these patterns, future upgrade scripts should:

### Core Steps (Always Required)
```bash
1. Validate environment and prerequisites
2. Check and upgrade Java if needed
3. Validate current version matches expected
4. Resolve any mixed state issues
5. Undeploy current version
6. Stop services in correct order
7. Backup configurations
8. Download and verify new components
9. Upgrade infrastructure components
10. Deploy new application
11. Update configurations and metadata
12. Restart services with health checks
13. Perform post-deployment operations
14. Verify upgrade completion
```

### Version-Specific Checklist
Check release notes for:
- [ ] Java version requirements
- [ ] Infrastructure component updates (Payara, Solr)
- [ ] Database schema changes
- [ ] Metadata block updates
- [ ] **New metadata fields** requiring Solr schema updates
- [ ] **Custom metadata blocks** that need field configuration
- [ ] Configuration changes
- [ ] Security updates
- [ ] Bug fixes requiring file modifications

### Schema Field Checklist (New from 6.5→6.6)
For upgrades with new metadata fields:
- [ ] **Identify all new fields** from release notes
- [ ] **Determine field properties** (multi-valued vs single-valued)
- [ ] **Create configuration options** for each field
- [ ] **Provide environment variable support** for customization
- [ ] **Include validation** for all field configurations
- [ ] **Support field disabling** for environments that don't need them
- [ ] **Create helper scripts** for easy configuration setup
- [ ] **Document all configuration options** clearly
- [ ] **Test with different configurations** (dev/staging/production)
- [ ] **Include comprehensive error handling** for schema issues
