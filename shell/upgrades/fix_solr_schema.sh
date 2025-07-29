#!/bin/bash

# Quick fix script to add missing software fields to Solr schema
# This addresses the "unknown field" errors during indexing

set -e

# Configuration
SOLR_PATH="/usr/local/solr"
SCHEMA_FILE="$SOLR_PATH/server/solr/collection1/conf/schema.xml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "Please do not run this script as root."
    exit 1
fi

# Check if schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    error "Schema file not found at: $SCHEMA_FILE"
    exit 1
fi

# Create backup
log "Creating backup of schema.xml..."
sudo cp "$SCHEMA_FILE" "${SCHEMA_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Find the line number where we should insert new fields (before SCHEMA-FIELDS::END)
insert_line=$(grep -n "SCHEMA-FIELDS::END" "$SCHEMA_FILE" | cut -d: -f1)
if [ -z "$insert_line" ]; then
    error "Could not find SCHEMA-FIELDS::END comment in schema.xml"
    exit 1
fi

log "Found insertion point at line $insert_line"

# Fix existing software fields with incorrect multiValued settings
log "Fixing existing software fields with incorrect multiValued settings..."

# Fix swDependencyDescription to be multiValued
sudo sed -i 's/<field name="swDependencyDescription" type="text_general" indexed="true" stored="true" multiValued="false"\/>/<field name="swDependencyDescription" type="text_general" indexed="true" stored="true" multiValued="true"\/>/' "$SCHEMA_FILE"

# Fix swFunction to be multiValued  
sudo sed -i 's/<field name="swFunction" type="text_general" indexed="true" stored="true" multiValued="false"\/>/<field name="swFunction" type="text_general" indexed="true" stored="true" multiValued="true"\/>/' "$SCHEMA_FILE"

log "Fixed existing fields"

# Add missing software fields
log "Adding missing software fields..."

# Fields that should be single-valued
single_valued_fields=(
    "swContributorRole"
    "swLicense"
    "swCodeRepositoryLink"
    "swInteractionMethod"
    "swDatePublished"
    "swContributorName"
)

# Add single-valued fields
for field in "${single_valued_fields[@]}"; do
    # Check if field already exists
    if ! grep -q "name=\"$field\"" "$SCHEMA_FILE"; then
        sudo sed -i "${insert_line}i\  <field name=\"$field\" type=\"text_general\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>" "$SCHEMA_FILE"
        log "  ✓ Added $field (multiValued=false)"
    else
        log "  - $field already exists, skipping"
    fi
done

log "All software fields processed successfully!"

# Restart Solr to apply schema changes
log "Restarting Solr to apply schema changes..."
sudo service solr restart

# Wait for Solr to be ready
log "Waiting for Solr to be ready..."
sleep 10

# Check if Solr is responding
if curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" | grep -q '"status":0'; then
    log "Solr is ready!"
else
    error "Solr is not responding after restart"
    exit 1
fi

# Reindex the data
log "Reindexing data to apply schema changes..."
curl -s "http://localhost:8080/api/admin/index" > /dev/null

if [ $? -eq 0 ]; then
    log "Reindexing started successfully!"
    log "You can monitor progress in the Payara logs"
else
    error "Failed to start reindexing"
    exit 1
fi

log "Fix completed successfully!"
log "The following actions were taken:"
echo "  - Fixed swDependencyDescription to be multiValued=true"
echo "  - Fixed swFunction to be multiValued=true"
echo "  - Added missing single-valued fields: ${single_valued_fields[*]}"
log "Solr has been restarted and reindexing has been initiated."