# Dataverse 6.5 to 6.6 Upgrade Script Analysis

## Issue Summary

The upgrade script `upgrade_6_5_to_6_6.sh` has a critical flaw in its Solr schema update mechanism. The script only adds a very limited set of software metadata fields and sets them all as `multiValued="false"`, when many should be `multiValued="true"`.

## Root Cause Analysis

### Current Upgrade Script Problems

1. **Incomplete Field Coverage**: The script only adds these software fields:
   - `swDescription` (single-valued)
   - `swTitle` (single-valued)
   - `swContributorName` (incorrectly set as single-valued)
   - `swInputOutputType` (incorrectly set as single-valued)
   - `swInputOutputDescription` (incorrectly set as single-valued)

2. **Incorrect MultiValued Settings**: The script sets all fields as `multiValued="false"` when many should be `multiValued="true"`

3. **Missing Fields**: The script completely misses many required software metadata fields

## Complete Software Metadata Field Requirements

Based on the error analysis, here are ALL the software fields that need to be added to the Solr schema:

### Multi-Valued Fields (can have multiple values)
```xml
<field name="swDependencyDescription" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swFunction" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swContributorName" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swContributorRole" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swContributorId" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swOtherRelatedResourceType" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swDependencyLink" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swInteractionMethod" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swLanguage" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swOtherRelatedResourceDescription" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swOtherRelatedSoftwareType" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swOtherRelatedSoftwareDescription" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swOtherRelatedSoftwareLink" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swContributorNote" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swInputOutputType" type="text_general" indexed="true" stored="true" multiValued="true"/>
<field name="swInputOutputDescription" type="text_general" indexed="true" stored="true" multiValued="true"/>
```

### Single-Valued Fields (should have only one value)
```xml
<field name="swCodeRepositoryLink" type="text_general" indexed="true" stored="true" multiValued="false"/>
<field name="swDatePublished" type="text_general" indexed="true" stored="true" multiValued="false"/>
<field name="howToCite" type="text_general" indexed="true" stored="true" multiValued="false"/>
<field name="swArtifactType" type="text_general" indexed="true" stored="true" multiValued="false"/>
<field name="swInputOutputLink" type="text_general" indexed="true" stored="true" multiValued="false"/>
<field name="swIdentifier" type="text_general" indexed="true" stored="true" multiValued="false"/>
```

## Recommended Fix for Upgrade Script

The upgrade script should be updated to:

1. **Add ALL missing fields** listed above
2. **Set correct multiValued settings** based on the field type
3. **Use proper field detection** to avoid duplicates
4. **Include comprehensive error handling**

### Suggested Script Improvements

```bash
# Add comprehensive software field detection
local software_fields_multi=(
    "swDependencyDescription"
    "swFunction"
    "swContributorName"
    "swContributorRole"
    "swContributorId"
    "swOtherRelatedResourceType"
    "swDependencyLink"
    "swInteractionMethod"
    "swLanguage"
    "swOtherRelatedResourceDescription"
    "swOtherRelatedSoftwareType"
    "swOtherRelatedSoftwareDescription"
    "swOtherRelatedSoftwareLink"
    "swContributorNote"
    "swInputOutputType"
    "swInputOutputDescription"
)

local software_fields_single=(
    "swCodeRepositoryLink"
    "swDatePublished"
    "howToCite"
    "swArtifactType"
    "swInputOutputLink"
    "swIdentifier"
)

# Add multi-valued fields
for field in "${software_fields_multi[@]}"; do
    if ! grep -q "name=\"$field\"" "$schema_file"; then
        # Add field with multiValued="true"
    fi
done

# Add single-valued fields
for field in "${software_fields_single[@]}"; do
    if ! grep -q "name=\"$field\"" "$schema_file"; then
        # Add field with multiValued="false"
    fi
done
```

## Testing Results

After applying the comprehensive fix:
- ✅ All software field errors resolved
- ✅ Reindexing completed successfully
- ✅ No SEVERE or ERROR messages in logs
- ✅ System upgrade completed successfully

## Files Created During Testing

1. `fix_solr_schema.sh` - Initial fix script
2. `fix_solr_schema_comprehensive.sh` - Comprehensive fix script
3. `SOLR_SCHEMA_FIX_SUMMARY.md` - Summary of fixes applied
4. `UPGRADE_SCRIPT_ANALYSIS.md` - This analysis document

## Next Steps

1. **Update the upgrade script** with the complete list of software fields
2. **Test the updated script** on a fresh installation
3. **Document the changes** in the release notes
4. **Consider automated testing** for schema field completeness

## Conclusion

The upgrade script needs significant improvement to handle the software metadata block properly. The current implementation is incomplete and will cause indexing failures during the upgrade process. 