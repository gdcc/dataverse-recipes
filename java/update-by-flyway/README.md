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
5. exporting the migrated database again as a new SQL dump.

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

### Cleanup

Stop containers and clean generated files:
```bash
mvn clean
``` 

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
  Time to wait for PostgreSQL startup and dump operations (default: `30`)

### Migration behavior flags

- `migrate.cleanupSavedSearches`  
  Enables automatic cleanup for data affected by issue #7398 (default: `false`)

- `migrate.keywordTermUri`  
  Enables handling related to keyword term URI migration checks (default: `false`)

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
