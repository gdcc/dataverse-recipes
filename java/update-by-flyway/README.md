# Dataverse Update By Flyway Migrations

## Description 📝

This recipe helps Dataverse administrators and operators upgrade a Dataverse installation by applying Flyway migrations directly against a local PostgreSQL database restored from a SQL dump of the installation.

It is intended for situations where you want to test or perform an upgrade without manually stepping through every intermediate Dataverse release one by one.
The required extra migrations are important because some database structures normally created during Dataverse setup are not present when working only from migration scripts.
These extra scripts help bridge that gap so later migrations can succeed.

The recipe works by:

1. checking out a specific tagged version of the Dataverse source repository (Maven SCM Plugin), 
2. starting a local PostgreSQL database in Docker (Maven Docker Plugin),
3. restoring a provided database dump into that database,
4. running the Dataverse Flyway migration scripts while including the required extra migration scripts included with this recipe (Maven Flyway Plugin),
5. running Flyway again but without the extra migrations and telling it to clean these up (which makes the dump compatible with Dataverse code again), 
6. exporting the final migrated database as a new SQL dump, ready to be imported into the installation.

The main output artifact is:

- `target/migrated_db_dump.sql`

Note: this may also help you upgrade to newer PostgreSQL versions by restoring the migrated dump.




## Prerequisites ✔️

Before using this recipe, make sure you have:

- **Java** installed
- **Maven** installed
- **Docker** installed and running
- A **PostgreSQL dump file** created with `pg_dump` (from your installation)
- Enough disk space for:
    - the checked-out Dataverse repository
    - a temporary PostgreSQL container
    - the restored database
    - the final migrated dump

### Important limitations

- This recipe is *experimental*
- This recipe is *not* an officially supported Dataverse upgrade path (yet...)
- It is intended for *local/offline testing and migration experiments*
- The minimum supported Dataverse version is *v4.12*
- You should work from a *database snapshot or dump*, not a live production database!

Because all migration work happens locally in Docker, it is generally safe to experiment with a production snapshot as long as you understand that this recipe is not an official upgrade mechanism.

#### What about potential data migrations for metadata blocks, fields and CVs?

This tool produces a migrated database dump but does **not** load any TSV files.
The admin will perform the final TSV reload (with the target version's TSVs) as part of deploying the new Dataverse version, following the standard upgrade procedure.
The question below addresses whether skipping the *intermediate* TSV reloads (those that would have happened between the source and target versions in a release-by-release upgrade) is safe.

We need to distinguish between "data definition migration" and "user data migration" scenarios.

##### Data Definition Migration

These are Flyway migrations that modify `metadatablock`, `datasetfieldtype`, `controlledvocabularyvalue`, or related definitional tables.

- If a migration's `WHERE` clause finds the targeted rows in the source DB, it applies as intended.
- If the targeted rows aren't there (because the source DB pre-dates their  introduction, or an admin already removed them), the migration silently affects zero rows.  
  Flyway considers this success. The end state is correct either way, because the target TSV either reintroduces what's needed or omits what's been removed.
- If a migration is written to fail loudly on missing state, we'll notice and can fix it.
- The only failure mode is a migration written too unspecifically (e.g., delete by hardcoded ID hitting an unintended row).
  This is a pre-existing risk for any upgrade path, not specific to this tool.

Update/rename migrations specifically can only target state introduced by a *previous* TSV reload, since Dataverse's upgrade process has always asked admins to reload TSVs *after* deploying, never before.
So on a too-old source DB they silently no-op, and on a sufficiently up-to-date source DB they apply normally - never silently wrong.

##### User Data Migration

If a Flyway migration updates user data (`datasetfield`, `datasetfieldvalue`) based on assumptions about which fields or CV values exist or have a certain state, we could be in trouble:
those assumptions may have been valid only after an intermediate TSV reload - which this tool skips.

**Audit method**: search migrations for any reference to the metadata-block-related tables and their dependents (the pattern is intentionally broad and will produce false positives requiring manual review):

```shell
grep -riEl '\b(metadatablock|datasetfieldtype|controlledvocabularyvalue|controlledvocabalternate|datasetfield|datasetfieldvalue|dataversefieldtypeinputlevel|dataversefacet|datasetfielddefaultvalue)\b' src/main/resources/db/migration/
```

This grep covers only SQL migrations. If Java-based Flyway migrations are added in the future, they require separate auditing.

**Audit results as of Dataverse 6.10.1**:

- `V5.3.0.3__7551-expanded-compound-datasetfield-validation.sql` — modifies `datasetfieldtype.required` and `dataversefieldtypeinputlevel` based on parent/child relationships; does not touch user data.
- `V5.8.0.2__8018-invalid-characters.sql` — uniform character sanitization on `datasetfieldvalue`; no TSV-state assumptions.
- `V5.10.1.1__8533-semantic-updates.sql` — adds unique constraint on `datasetfieldtype.name`; schema-only.
- `V6.1.0.4__5645-geospatial-fieldname-fix.sql` — renames two `datasetfieldtype` rows by name; idempotent, no user-data impact.
- `V6.5.0.6.sql` / `V6.5.0.12.sql` — adds column and index on `dataversefieldtypeinputlevel`; schema-only.

None of these update user-entered data based on assumptions about TSV-loaded state.
Schema changes, uniform sanitization, and idempotent renames only. ✅

##### Requirement for future migrations

Any future migration that updates user data based on metadata-block state **must** explicitly verify its expected starting state and fail loudly if the state is absent or unexpected.
Two patterns to be aware of:

**Existence checks** — when a migration assumes a particular field or CV value exists:

```sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM datasetfieldtype WHERE name = 'expectedField') THEN
    RAISE EXCEPTION 'Migration prerequisite missing: datasetfieldtype "expectedField" not found. Run the previous release''s TSV load first.';
  END IF;
  -- ... rest of migration ...
END $$;
```

**Attribute-state checks** — when a migration assumes a field/CV row has a particular attribute value (e.g., `required=true`, a specific `fieldType`, a specific `displayOrder`, membership in a particular `metadatablock`).
This is the more dangerous case: the row exists, so an existence check passes, but the migration's logic depends on an attribute that may only have been set by a previous TSV reload.
Verify the attribute explicitly:

```sql
DO $$
DECLARE
  expected_required boolean;
  expected_fieldtype text;
BEGIN
  SELECT required, fieldtype INTO expected_required, expected_fieldtype
    FROM datasetfieldtype WHERE name = 'expectedField';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Migration prerequisite missing: datasetfieldtype "expectedField" not found.';
  END IF;

  IF expected_required IS DISTINCT FROM true OR expected_fieldtype IS DISTINCT FROM 'TEXT' THEN
    RAISE EXCEPTION 'Migration prerequisite mismatch: datasetfieldtype "expectedField" has required=%, fieldtype=%, expected required=true, fieldtype=TEXT. Run the previous release''s TSV load first.',
      expected_required, expected_fieldtype;
  END IF;

  -- ... migration that depends on these attributes, e.g. updating
  -- datasetfieldvalue rows based on the field being required ...
END $$;
```

The same pattern applies to `controlledvocabularyvalue` (e.g., verifying `strvalue`, `identifier`, or `datasetfieldtype_id` before using a CV value to update user data) and to `metadatablock` (verifying `name` or block membership).

Both check patterns protect all upgrade paths — including this tool, release-by-release upgrades, and installations where admins have forgotten a TSV reload or have diverged locally from upstream definitions.

##### Locally customized upstream metadata blocks

For customized upstream metadata blocks (e.g., a modified `citation.tsv`), the risks are the same as with release-by-release upgrades:
the next TSV reload overwrites local customizations.
Admins with local customizations should diff their TSVs against upstream before running this tool and carefully reapply changes after the upgrade.

### Recommendations 🗒️

- Always start from a reliable `pg_dump` backup
- Prefer testing with a copy of production data, not the live database itself
- Review migration notices carefully, especially when enabling cleanup flags
- Keep in mind that this recipe is a practical migration aid, not an official Dataverse-supported upgrade method
- Validate the migrated database before using it further in any environment




## Installation instructions 🔧

1. Clone this recipe repository and change your working directory to `java/update-by-flyway`.
2. Make sure Docker is running.
3. Place your PostgreSQL dump where the recipe can read it or override the dump file location with a Maven property (see below).




## Usage examples 💻

### Basic usage

Run the full migration workflow:
```bash
mvn install
```

This will:

- check out the configured Dataverse tag
- start PostgreSQL in Docker
- restore your dump
- apply Flyway migrations
- apply the required extra migrations shipped with this recipe
- export the migrated database as `target/migrated_db_dump.sql`
- stop the container and remove it

Note: for most production setups, the database dump is quite huge.
Make sure to inspect the `postgresql.waitForSec` to allow for ample time of restoring the DB from the dump.

### Cleanup

Stop containers and clean generated files:
```bash
mvn clean
``` 

### Exploring

If you want to examine the database contents before or after the migration without stopping, you have two choices.

Only import the dump, then wait (non-blocking!):
```bash
mvn prepare-package
```

Migrate, then wait (non-blocking!):
```bash
mvn package
```

The container will listen on `${postgresql.host}:${postgresql.port}`, defaulting to `localhost:15432`.

### Use a different Dataverse tag

To migrate using another Dataverse release tag:
```bash
mvn install -Drepo.tag=v6.10.1
```

### Use a different input dump file

```bash
mvn install -Dpostgresql.dump.file=/path/to/db_dump.sql
``` 

### Change PostgreSQL connection settings

```bash
mvn install
-Dpostgresql.host=localhost
-Dpostgresql.port=15432
-Dpostgresql.db=dataverse
-Dpostgresql.username=dataverse
-Dpostgresql.password=supersecret
```

Note: by setting `-Ddocker.skip` and configuring a Postgres connection to a live database, you can run the migrations
on a non-local database, too.


### Enable cleanup of affected saved searches and links

This recipe includes a required extra migration for handling data related to Dataverse issue #7398.
By default, the script detects affected rows and prints notices.
To actually perform the cleanup automatically, enable:

```bash
mvn install -Dmigrate.cleanupSavedSearches=true
``` 

This can remove:

- affected saved searches
- affected linked datasets
- affected linked collections

Use this only if you understand the data impact and want the migration to perform the cleanup instead of only reporting it.

### Enable keyword term URI migration handling

This recipe also includes a required extra migration related to `keywordValue` values that look like URLs and may need to become `keywordTermURI` values.

Run with:
```bash
mvn install -Dmigrate.keywordTermUri=true
```

At the moment, this migration mainly serves as a detection and guidance step.
It checks for affected metadata values and emits notices explaining the situation.
This is useful when reviewing upgrade issues around Dataverse 6.3 and related metadata handling.

### Run additional, local migrations

In case you are migrating from a fork back to upstream code, you might want to add additional data migrations.
You may put these in a folder and point to it by Maven property:

```bash
mvn install -Dmigrate.local=path/to/your/local/migrations
```



## Important Maven properties ⚙️

These are the most useful properties to override when running the recipe.

### Dataverse source selection

- `repo.url`  
  Git URL of the Dataverse repository to check out (default: `https://github.com/IQSS/dataverse.git`)

- `repo.tag`  
  Dataverse Git tag to use for migration scripts (default: `v6.10.1`)

- `repo.directory`  
  Local checkout directory for the Dataverse repository (default: `${project.build.directory}/dataverse`)

- `repo.subpath`  
  Path inside the checked-out repository that contains the Flyway migrations (default: `src/main/resources/db/migration`)

### Input and output dump handling

- `postgresql.dump.file`  
  Path to the input PostgreSQL dump file (default `db_dump.sql`)

- `postgresql.dump.file.ext`  
  Extension of the input dump file (default: `sql`)

- `postgresql.dump.target`  
  Directory where the migrated dump is written (default: `target`).
  The resulting migrated dump is written as: `${postgresql.dump.target}/migrated_db_dump.sql`

### PostgreSQL settings

- `postgresql.server.version`  
  PostgreSQL Docker image version to use (default: `16`)

- `postgresql.host`  
  Host used by Flyway to connect (default: `localhost`)

- `postgresql.port`  
  Local port mapped to the Docker PostgreSQL container (default: `15432`)

- `postgresql.db`  
  Database name (default: `dataverse`)

- `postgresql.username`  
  Database user (default: `dataverse`)

- `postgresql.password`  
  Database password (default: `supersecret`)

- `postgresql.waitForSec`  
  Time to wait for PostgreSQL startup and dump operations (default: `600` = 10 minutes)

### Migration behavior flags

- `migrate.cleanupSavedSearches`  
  Enables automatic cleanup for data affected by issue #7398 (default: `false`)

- `migrate.keywordTermUri`  
  Enables handling related to keyword term URI migration checks (default: `false`)

- `migrate.local`
  Point to directory with additional, local migration scripts. Skipped if it does not exist. (default: `${project.basedir}/local`)

### Docker execution control

These are mostly useful for debugging or partial reruns:

- `docker.skip`
- `docker.skipStart`
- `docker.skipDump`
- `docker.skipStop`




## Dependencies 📦

This recipe depends on you to provide:

- **Maven**
- **Docker**

It will automatically pull in these dependencies:
- **PostgreSQL Docker image**
- **Flyway Maven Plugin**
- **Flyway PostgreSQL support**
- **PostgreSQL JDBC driver**
- **Maven SCM Plugin**
- **Docker Maven Plugin**

It also depends on access to the Dataverse Git repository, so the main migration scripts for the configured tag can be checked out locally.




## Support 💬

For issues and questions, please open an issue in this repository or discuss on the Dataverse Zulip community channels if appropriate.
