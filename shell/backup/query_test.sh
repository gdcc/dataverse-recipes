#!/bin/bash

# Database inspection script
# Example: ./query_test.sh 

DB_NAME=dvndb

# Get user's home directory
USER_HOME=$(eval echo ~$USER)

# Ensure the script is run as the postgres user
if [ "$(whoami)" != "postgres" ]; then
  # Re-execute the script as the postgres user, passing all original arguments
  sudo -u postgres "$0" "$@"
  # Exit the current script. The exit status of this script will be the exit status of the sudo command.
  exit $?
fi

# Function to execute PostgreSQL queries
run_query() {
  local db=$1
  local query=$2
  psql -d "$db" -t -c "$query"
}

# Function to export template metadata
export_template() {
  local db=$1
  local template_name=$2
  
  echo "Exporting template: $template_name"
  echo "----------------------------------------"
  
  local query="
  SELECT
    -- Template details
    t.id AS template_id,
    t.name AS template_name,
    t.instructions AS template_instructions,
    t.createtime AS template_createtime,
    t.usagecount AS template_usagecount,

    -- Terms of Use and Access details
    toa.id AS termsofuseandaccess_id,
    toa.termsofuse,
    toa.availabilitystatus,
    toa.citationrequirements,
    toa.conditions,
    toa.confidentialitydeclaration,
    toa.contactforaccess,
    toa.dataaccessplace,
    toa.depositorrequirements,
    toa.disclaimer,
    toa.fileaccessrequest AS toua_fileaccessrequest,
    toa.originalarchive,
    toa.restrictions AS toua_restrictions,
    toa.sizeofcollection,
    toa.specialpermissions,
    toa.studycompletion,
    toa.termsofaccess,
    toa.license_id,
    lic.name AS license_name,
    lic.uri AS license_uri,
    lic.iconurl AS license_iconurl,

    -- Field details from datasetfieldtype
    dft.id AS field_type_id,
    dft.name AS field_type_name,
    dft.title AS field_type_title,
    dft.description AS field_type_description,
    dft.fieldtype AS field_type_fieldtype,
    dft.allowmultiples AS field_type_allowmultiples,
    dft.required AS field_type_is_globally_required,
    dft.displayorder AS field_type_displayorder,
    dft.parentdatasetfieldtype_id AS field_type_parent_id,
    dft.allowcontrolledvocabulary AS field_type_allow_cv,
    dft.uri AS field_type_uri,
    dft.validationformat AS field_type_validation_format,
    dft.displayformat AS field_type_display_format,
    dft.watermark AS field_type_watermark,
    dft.advancedsearchfieldtype AS field_type_advanced_search,
    dft.facetable AS field_type_facetable,
    dft.displayoncreate AS field_type_display_on_create,

    -- Metadata Block details
    mb.id AS metadatablock_id,
    mb.name AS metadatablock_name,
    mb.displayname AS metadatablock_displayname,
    mb.namespaceuri AS metadatablock_namespaceuri,

    -- Controlled Vocabulary Values
    (
      SELECT json_agg(
        json_build_object(
          'id', cvv.id,
          'value', cvv.strvalue,
          'identifier', cvv.identifier,
          'displayOrder', cvv.displayorder,
          'alternates', (
            SELECT json_agg(
              json_build_object('id', cva.id, 'value', cva.strvalue)
            )
            FROM public.controlledvocabalternate cva
            WHERE cva.controlledvocabularyvalue_id = cvv.id
              AND cva.datasetfieldtype_id = dft.id
          )
        ) ORDER BY cvv.displayorder
      )
      FROM public.controlledvocabularyvalue cvv
      WHERE cvv.datasetfieldtype_id = dft.id 
        AND dft.allowcontrolledvocabulary = TRUE
    ) AS controlled_vocabulary_values
  FROM
    public.template t
  JOIN
    public.datasetfield df ON t.id = df.template_id
  JOIN
    public.datasetfieldtype dft ON df.datasetfieldtype_id = dft.id
  LEFT JOIN
    public.metadatablock mb ON dft.metadatablock_id = mb.id
  LEFT JOIN
    public.termsofuseandaccess toa ON t.termsofuseandaccess_id = toa.id
  LEFT JOIN
    public.license lic ON toa.license_id = lic.id
  WHERE
    t.name = '$template_name'
  ORDER BY
    mb.displayname, dft.displayorder, dft.name;"

  # Execute the query and format the output
  echo "Template Metadata Export Results:"
  echo "----------------------------------------"
  run_query "$db" "$query" | while IFS='|' read -r line; do
    echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  done
}

# Function to check template configuration
check_template_config() {
  local db=$1
  local template_name=$2
  
  echo "Checking template configuration for: $template_name"
  echo "----------------------------------------"
  
  # Check template association with dataverse
  local query="
  SELECT 
    t.id as template_id,
    t.name as template_name,
    d.id as dataverse_id,
    d.name as dataverse_name,
    d.defaulttemplate_id,
    d.metadatablockroot,
    d.templateroot
  FROM 
    public.template t
  LEFT JOIN 
    public.dataverse d ON t.dataverse_id = d.id
  WHERE 
    t.name = '$template_name';"
  
  echo "Template-Dataverse Association:"
  run_query "$db" "$query"
  echo "----------------------------------------"
  
  # Check metadata block associations
  query="
  SELECT 
    mb.name as metadatablock_name,
    mb.displayname as metadatablock_displayname,
    dm.dataverse_id,
    d.name as dataverse_name
  FROM 
    public.template t
  JOIN 
    public.datasetfield df ON t.id = df.template_id
  JOIN 
    public.datasetfieldtype dft ON df.datasetfieldtype_id = dft.id
  JOIN 
    public.metadatablock mb ON dft.metadatablock_id = mb.id
  LEFT JOIN 
    public.dataverse_metadatablock dm ON mb.id = dm.metadatablocks_id
  LEFT JOIN 
    public.dataverse d ON dm.dataverse_id = d.id
  WHERE 
    t.name = '$template_name'
  GROUP BY 
    mb.name, mb.displayname, dm.dataverse_id, d.name;"
  
  echo "Metadata Block Associations:"
  run_query "$db" "$query"
  echo "----------------------------------------"
  
  # Check field input levels
  query="
  SELECT 
    dft.name as field_name,
    dft.title as field_title,
    d.name as dataverse_name,
    dfil.include,
    dfil.required
  FROM 
    public.template t
  JOIN 
    public.datasetfield df ON t.id = df.template_id
  JOIN 
    public.datasetfieldtype dft ON df.datasetfieldtype_id = dft.id
  LEFT JOIN 
    public.dataversefieldtypeinputlevel dfil ON dft.id = dfil.datasetfieldtype_id
  LEFT JOIN 
    public.dataverse d ON dfil.dataverse_id = d.id
  WHERE 
    t.name = '$template_name'
  ORDER BY 
    dft.name;"
  
  echo "Field Input Levels:"
  run_query "$db" "$query"
}

# Main script logic
if [ $# -eq 0 ]; then
  echo "Usage: $0 <template_name>"
  echo "Example: $0 'My Template'"
  exit 1
fi

TEMPLATE_NAME="$1"
check_template_config "$DB_NAME" "$TEMPLATE_NAME"

