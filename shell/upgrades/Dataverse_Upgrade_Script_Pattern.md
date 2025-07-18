# Dataverse Upgrade Script Pattern
## Core Upgrade Pattern (Universal Steps)

Every Dataverse upgrade follows this fundamental sequence:

### 1. Pre-Upgrade Validation
- Check current version matches expected version
- Validate environment variables (.env file)
- Check required system commands
- Verify disk space and system resources

### 2. Application Lifecycle Management
```bash
# Standard sequence for ALL upgrades:
1. Undeploy current Dataverse version
2. Stop Payara application server
3. Stop Solr search engine
4. Download new WAR file
5. Deploy new WAR file to Payara
6. Start services (Payara, then Solr)
7. Wait for site availability
```

### 3. Post-Deployment Verification
- Check deployed version via API
- Verify services are responding correctly

## Version-Specific Variations

### Major Infrastructure Changes (5.14 → 6.0)
This was a **major upgrade** requiring infrastructure changes:
- **Java upgrade** (Java 8 → Java 17)
- **Payara upgrade** (Payara 5 → Payara 6) 
- **Solr upgrade** (Solr 8 → Solr 9.3.0)
- **Complete service migration** (moving from old to new versions)
- **Configuration migration** (domain.xml, service files, paths)

### Minor Version Updates (6.0 → 6.1, 6.1 → 6.2)
These follow the **standard pattern** with specific additions:

#### Common Extras for Minor Versions:
1. **Metadata block updates** (.tsv files)
   - Citation metadata block
   - Geospatial metadata block  
   - Domain-specific blocks (astrophysics, biomedical)

2. **Solr schema updates**
   - Download new schema.xml or update-fields.sh
   - Update field definitions
   - Reindex if needed

3. **Configuration updates**
   - New JVM options
   - Feature toggles/settings
   - Bug fixes (like the DOI→DOI text replacement)

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

## Template for 6.2 → 6.3 Upgrade

Based on this pattern analysis, here's what your 6.2 → 6.3 script should include:

### Core Steps (Always Required)
```bash
1. Validate current version (6.2)
2. Undeploy dataverse-6.2
3. Stop Payara
4. Download dataverse-6.3.war (with hash verification)
5. Deploy dataverse-6.3.war
6. Start Payara
7. Wait for site availability
8. Verify version via API
```

### Version-Specific Steps (Check 6.3 Release Notes)
Look for these common patterns in the 6.3 release notes:

#### Metadata Updates
- [ ] Citation metadata block updates?
- [ ] Geospatial metadata block updates?
- [ ] New domain-specific metadata blocks?
- [ ] Custom field additions?

#### Solr Changes
- [ ] Schema.xml updates?
- [ ] New field definitions?
- [ ] Index rebuilding required?

#### Configuration Changes
- [ ] New JVM options?
- [ ] Database schema changes?
- [ ] New feature settings?
- [ ] Security updates?

#### Bug Fixes
- [ ] File content corrections?
- [ ] Text/translation updates?
- [ ] UI fixes requiring file modifications?
