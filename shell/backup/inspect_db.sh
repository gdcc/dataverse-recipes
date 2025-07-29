#!/bin/bash

# Database inspection script
# Usage: ./inspect_db.sh [database_name]
# Example: ./inspect_db.sh dvndb
# If no database is specified, all databases will be inspected

DB_NAME=$1

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

# Function to process a single database
process_database() {
  local db=$1
  local output_file=$2

  echo "Inspecting database: $db"
  echo "Database: $db" >> "$output_file"
  echo "===========================================" >> "$output_file"
  echo "" >> "$output_file"

  # Get database size
  echo "Database Size:" >> "$output_file"
  run_query "$db" "SELECT pg_size_pretty(pg_database_size('$db'));" >> "$output_file"
  echo "" >> "$output_file"

  # Get database encoding and collation
  echo "Database Properties:" >> "$output_file"
  run_query "$db" "
  SELECT
    'Encoding: ' || pg_encoding_to_char(encoding) || E'\n' ||
    'Collation: ' || datcollate || E'\n' ||
    'Character Type: ' || datctype
  FROM pg_database
  WHERE datname = '$db';" >> "$output_file"
  echo "" >> "$output_file"

  # Get list of all tables
  echo "Gathering table list..."
  local TABLES=$(run_query "$db" "
  SELECT table_schema || '.' || table_name
  FROM information_schema.tables
  WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    AND table_type = 'BASE TABLE'
  ORDER BY table_schema, table_name;")

  # Process each table
  echo "$TABLES" | while read -r TABLE_FULL_NAME; do
    if [ -z "$TABLE_FULL_NAME" ]; then continue; fi

    SCHEMA=$(echo "$TABLE_FULL_NAME" | cut -d'.' -f1)
    TABLE=$(echo "$TABLE_FULL_NAME" | cut -d'.' -f2)

    echo "Processing table: $TABLE_FULL_NAME"

    # Write table header
    echo "Table: $TABLE_FULL_NAME" >> "$output_file"
    echo "-------------------------------------------" >> "$output_file"

    # Get table description and size
    echo "Basic Information:" >> "$output_file"
    run_query "$db" "
    SELECT
      'Description: ' || COALESCE(obj_description(pgc.oid, 'pg_class'), 'No description') || E'\n' ||
      'Size: ' || pg_size_pretty(pg_total_relation_size(pgc.oid)) || E'\n' ||
      'Last vacuum: ' || COALESCE(last_vacuum::text, 'never') || E'\n' ||
      'Last autovacuum: ' || COALESCE(last_autovacuum::text, 'never') || E'\n' ||
      'Last analyze: ' || COALESCE(last_analyze::text, 'never') || E'\n' ||
      'Last autoanalyze: ' || COALESCE(last_autoanalyze::text, 'never')
    FROM pg_class pgc
    LEFT JOIN pg_stat_user_tables psut ON pgc.relname = psut.relname
    WHERE pgc.relname = '$TABLE';" >> "$output_file"
    echo "" >> "$output_file"

    # Get column information
    echo "Columns:" >> "$output_file"
    echo "| Column | Type | Nullable | PK | FK | Default | Description |" >> "$output_file"
    echo "|--------|------|----------|----|----|---------|-------------|" >> "$output_file"

    run_query "$db" "
    SELECT
      '| ' || c.column_name ||
      ' | ' || c.data_type ||
      CASE WHEN c.character_maximum_length IS NOT NULL
           THEN '(' || c.character_maximum_length || ')'
           ELSE '' END ||
      ' | ' || c.is_nullable ||
      ' | ' || CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.key_column_usage kcu
        WHERE kcu.table_schema = c.table_schema
          AND kcu.table_name = c.table_name
          AND kcu.column_name = c.column_name
          AND kcu.position_in_unique_constraint IS NULL
      ) THEN '✓' ELSE '' END ||
      ' | ' || CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.key_column_usage kcu
        WHERE kcu.table_schema = c.table_schema
          AND kcu.table_name = c.table_name
          AND kcu.column_name = c.column_name
          AND kcu.position_in_unique_constraint IS NOT NULL
      ) THEN '✓' ELSE '' END ||
      ' | ' || COALESCE(column_default, '') ||
      ' | ' || COALESCE(col_description(pgc.oid, c.ordinal_position), '') || ' |'
    FROM information_schema.columns c
    JOIN pg_class pgc ON c.table_name = pgc.relname
    WHERE c.table_schema = '$SCHEMA'
      AND c.table_name = '$TABLE'
    ORDER BY c.ordinal_position;" >> "$output_file"
    echo "" >> "$output_file"

    # Get foreign key relationships
    echo "Foreign Key Relationships:" >> "$output_file"
    run_query "$db" "
    SELECT
      '  ' || kcu.column_name || ' -> ' ||
      ccu.table_schema || '.' || ccu.table_name || '.' || ccu.column_name ||
      ' (' || tc.constraint_name || ')'
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = '$SCHEMA'
      AND tc.table_name = '$TABLE';" >> "$output_file"
    echo "" >> "$output_file"

    # Get indexes
    echo "Indexes:" >> "$output_file"
    run_query "$db" "
    SELECT '  ' || indexname || ': ' || indexdef
    FROM pg_indexes
    WHERE schemaname = '$SCHEMA'
      AND tablename = '$TABLE';" >> "$output_file"
    echo "" >> "$output_file"

    # Get triggers
    echo "Triggers:" >> "$output_file"
    run_query "$db" "
    SELECT '  ' || tgname || ': ' || pg_get_triggerdef(oid)
    FROM pg_trigger
    WHERE tgrelid = '\"$SCHEMA\".\"$TABLE\"'::regclass
    AND NOT tgisinternal;" >> "$output_file"
    echo "" >> "$output_file"

    # Add sample data count and size statistics
    echo "Statistics:" >> "$output_file"
    run_query "$db" "
    SELECT
      '  Row count: ' || reltuples::bigint || E'\n' ||
      '  Size: ' || pg_size_pretty(pg_total_relation_size('\"$SCHEMA\".\"$TABLE\"'::regclass)) || E'\n' ||
      '  Table size: ' || pg_size_pretty(pg_relation_size('\"$SCHEMA\".\"$TABLE\"'::regclass)) || E'\n' ||
      '  Index size: ' || pg_size_pretty(pg_total_relation_size('\"$SCHEMA\".\"$TABLE\"'::regclass) - pg_relation_size('\"$SCHEMA\".\"$TABLE\"'::regclass)) || E'\n' ||
      '  Toast size: ' || pg_size_pretty(pg_total_relation_size(reltoastrelid))
    FROM pg_class
    WHERE oid = '\"$SCHEMA\".\"$TABLE\"'::regclass;" >> "$output_file"
    echo "" >> "$output_file"

    # Add separator between tables
    echo "==========================================" >> "$output_file"
    echo "" >> "$output_file"
  done
}

# Create output directory if it doesn't exist
OUTPUT_DIR="$USER_HOME/db_inspections"
mkdir -p "$OUTPUT_DIR"

# Get current timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [ -z "$DB_NAME" ]; then
  echo "No database specified. Inspecting all databases..."

  # Get list of all databases excluding template and postgres system databases
  DATABASES=$(psql -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres') ORDER BY datname;")

  # Create a master output file
  MASTER_OUTPUT="$OUTPUT_DIR/all_databases_inspection_$TIMESTAMP.txt"
  echo "Database Inspection Report" > "$MASTER_OUTPUT"
  echo "Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$MASTER_OUTPUT"
  echo "===========================================" >> "$MASTER_OUTPUT"
  echo "" >> "$MASTER_OUTPUT"

  # Process each database
  echo "$DATABASES" | while read -r db; do
    if [ -z "$db" ]; then continue; fi

    echo "Processing database: $db"
    DB_OUTPUT="$OUTPUT_DIR/${db}_inspection_$TIMESTAMP.txt"

    # Add database header to master file
    echo "Database: $db" >> "$MASTER_OUTPUT"
    echo "See detailed report: ${db}_inspection_$TIMESTAMP.txt" >> "$MASTER_OUTPUT"
    echo "-------------------------------------------" >> "$MASTER_OUTPUT"

    # Get database size and basic info for master file
    run_query "$db" "
    SELECT
      'Size: ' || pg_size_pretty(pg_database_size('$db')) || E'\n' ||
      'Encoding: ' || pg_encoding_to_char(encoding) || E'\n' ||
      'Tables: ' || (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema'))
    FROM pg_database
    WHERE datname = '$db';" >> "$MASTER_OUTPUT"
    echo "" >> "$MASTER_OUTPUT"

    # Process the database
    process_database "$db" "$DB_OUTPUT"
  done

  echo "Inspection complete. Results saved to:"
  echo "  Master report: $MASTER_OUTPUT"
  echo "  Individual reports in: $OUTPUT_DIR"
else
  # Process single database
  OUTPUT_FILE="$OUTPUT_DIR/${DB_NAME}_inspection_$TIMESTAMP.txt"
  echo "Database Inspection Report" > "$OUTPUT_FILE"
  echo "Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$OUTPUT_FILE"
  echo "===========================================" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  process_database "$DB_NAME" "$OUTPUT_FILE"
  echo "Inspection complete. Results saved to: $OUTPUT_FILE"
  
fi