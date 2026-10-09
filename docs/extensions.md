# PostgreSQL Extensions in Postbase

Postbase runs on **PostgreSQL 18**. Extensions are installed **once per
database** (not per project): Postbase keeps every project's data in its own
`proj_<id>` schema inside a single database, so anything you enable is available
to all projects on the instance.

This image (`postbase` + Swagger + MCP) ships three layers of extensions:

| Layer | Included |
| --- | --- |
| PostgreSQL core | `plpgsql` |
| `postgresql18-contrib` | 45 standard extensions (`pgcrypto`, `uuid-ossp`, `pg_trgm`, `hstore`, …) |
| Installed at build time (Dockerfile `pgbuilder` stage) | `pgmq` 1.13.0 (pure SQL), `pg_cron` 1.6.8 (compiled to `pg_cron.so`) |

## How to install an extension

1. **Dashboard → Integrations** — the guided route for the two "modules"
   Postbase treats as first-class features (`pgmq`, `pg_cron`). The button runs
   `CREATE EXTENSION` for you.
2. **Dashboard → SQL Editor** (or any SQL client) —
   `CREATE EXTENSION IF NOT EXISTS <name>;`
3. **Bake it into the image** — add the Alpine package in the `Dockerfile`
   (runner stage) and rebuild. See
   [Optional modules](#optional-modules-require-an-extra-package).

Inspect what the server can install and what is already loaded:

```sql
-- everything the server can install
SELECT name, default_version, installed_version
FROM pg_available_extensions ORDER BY name;

-- already installed, and the schema its objects live in
SELECT e.extname, e.extversion, n.nspname
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY 1;
```

## Always enabled

Created by `scripts/init.sql` on the first boot:

| Extension | Purpose |
| --- | --- |
| `plpgsql` | PL/pgSQL procedural language (PostgreSQL core — always present) |
| `uuid-ossp` | `uuid_generate_v4()` and the other UUID generators |
| `pgcrypto` | Hashing (`digest`, `crypt`), HMAC, PGP encryption, `gen_random_uuid()` |

## Postbase modules (Integrations page)

The dashboard exposes exactly these two as installable "integrations":

| Module | Dashboard tab | What it gives you | Server restart |
| --- | --- | --- | --- |
| `pgmq` | *Integrations → Queues* | Message queue with visibility timeouts — send / read / delete / purge, like AWS SQS | Not required |
| `pg_cron` | *Integrations → Cron* | Scheduled SQL and HTTP jobs (`cron.schedule`) | Required — needs `shared_preload_libraries` (the entrypoint sets it) |

Naming: Postbase prefixes every queue and cron job with
`pb_<projectId_without_dashes>_`, so projects sharing the database never collide.

Install either of them with:

```sql
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

> The dashboard's **Database → Extensions** page is a placeholder in the current
> upstream build ("No extensions found"). Use the Integrations page or SQL.

## Built-in contrib modules — ready to use

All 45 extensions below are provided by `postgresql18-contrib`, which this image
installs. `CREATE EXTENSION IF NOT EXISTS <name>;` works immediately, no rebuild.

| Extension | Purpose |
| --- | --- |
| `amcheck` | Verify the logical/physical consistency of relations (`bt_index_check`) |
| `autoinc` | Trigger that auto-increments a counter column |
| `bloom` | Bloom-filter index access method |
| `btree_gin` | GIN operator classes for btree-indexable types |
| `btree_gist` | GiST operator classes for btree-indexable types |
| `citext` | Case-insensitive `text` type |
| `cube` | Multidimensional cube data type |
| `dblink` | Query other PostgreSQL databases from the current session |
| `dict_int` | Text-search dictionary for integers |
| `dict_xsyn` | Text-search dictionary with synonym support |
| `earthdistance` | Great-circle distances on the Earth |
| `file_fdw` | Foreign-data wrapper for flat files |
| `fuzzystrmatch` | Levenshtein, Soundex, Metaphone, dmetaphone |
| `hstore` | Key/value pair (`hstore`) data type |
| `insert_username` | Trigger that records who last changed a row |
| `intagg` | Integer aggregator / enumerator (obsolete, still shipped) |
| `intarray` | Indexing and querying of `integer[]` arrays |
| `isn` | Types for ISBN / EAN / UPC / ISMN product numbers |
| `lo` | Manage large objects (`lo_*` functions) |
| `ltree` | Hierarchical tree-like label data type + search |
| `moddatetime` | Trigger that tracks the last modification time |
| `pageinspect` | Low-level inspection of database pages |
| `pg_buffercache` | Inspect the shared buffer cache |
| `pg_freespacemap` | Inspect the free space map |
| `pg_logicalinspect` | Inspect logical-decoding components (new in PostgreSQL 18) |
| `pg_prewarm` | Load relation data into the OS/PostgreSQL cache |
| `pg_stat_statements` | Execution statistics per SQL statement (**needs preload**) |
| `pg_surgery` | Low-level surgery on corrupted relation data |
| `pg_trgm` | Trigram similarity, fuzzy search, fast `LIKE`/`ILIKE` |
| `pg_visibility` | Inspect the visibility map and page-level visibility |
| `pg_walinspect` | Inspect the contents of WAL files |
| `pgcrypto` | Cryptographic and hashing functions (**already enabled**) |
| `pgrowlocks` | Show row-level locking information |
| `pgstattuple` | Tuple-level statistics (bloat, dead tuples) |
| `postgres_fdw` | Foreign-data wrapper for remote PostgreSQL servers |
| `refint` | Referential-integrity functions |
| `seg` | Numeric interval / range (`seg`) data type |
| `sslinfo` | Information about the client's SSL certificate |
| `tablefunc` | Table-returning functions: `crosstab`, `connectby` |
| `tcn` | Trigger-based change notification |
| `tsm_system_rows` | `TABLESAMPLE` method taking a row count |
| `tsm_system_time` | `TABLESAMPLE` method taking a time budget |
| `unaccent` | Text-search dictionary that removes accents |
| `uuid-ossp` | UUID generation (**already enabled**) |
| `xml2` | XPath and XSLT functions for SQL/XML |

## Optional modules (require an extra package)

These are **not** in the image. Add the Alpine package in the **runner** stage of
the `Dockerfile` (they live in the `community` repository, already enabled) and
rebuild:

```dockerfile
RUN apk add --no-cache postgresql18 postgresql18-client postgresql18-contrib postgresql-common \
                       postgresql-pgvector \
                       supervisor su-exec curl
```

### Verified for PostgreSQL 18 (Alpine v3.23)

| Alpine package | Version | Extension(s) | Use case |
| --- | --- | --- | --- |
| `postgresql-pgvector` | 0.8.1 | `vector` | Embeddings / vector similarity search (AI, RAG) |
| `postgis` | 3.6.1 | `postgis`, `postgis_raster`, `postgis_topology`, … | Geographic objects and spatial queries |
| `postgresql-timescaledb` | 2.23.0 | `timescaledb` | Time-series tables, continuous aggregates (**needs preload**) |
| `postgresql-pg_cron` | 1.6.7 | `pg_cron` | Job scheduler — the image compiles 1.6.8 upstream, so this package is optional |
| `postgresql-hypopg` | 1.4.2 | `hypopg` | Hypothetical indexes for `EXPLAIN` what-if analysis |
| `postgresql-rum` | 1.3.15 | `rum` | RUM index for full-text search with ranking |
| `postgresql-orafce` | 4.10.0 | `orafce` | Oracle compatibility functions |
| `postgresql-plpgsql_check` | 2.8.3 | `plpgsql_check` | Static analysis / linting of PL/pgSQL |
| `postgresql-pg_roaringbitmap` | 0.5.4 | `roaringbitmap` | Compressed bitmap data type |
| `postgresql-login_hook` | 1.6 | `login_hook` | Run code on user login (**needs preload**) |
| `postgresql-mysql_fdw` | 2.9.3 | `mysql_fdw` | Query MySQL/MariaDB from PostgreSQL |
| `postgresql-sequential-uuids` | 1.0.2 | `sequential_uuids` | Time-ordered, index-friendly UUIDs |
| `postgresql-temporal_tables` | 1.2.2 | `temporal_tables` | System-versioned (temporal) tables |
| `postgresql-shared_ispell` | 1.1.0 | `shared_ispell` | Shared Ispell dictionaries (**needs preload**) |
| `postgresql-uint` | 1.20231206 | `uint` | Unsigned integer types |
| `postgresql-url_encode` | 1.2.5 | `url_encode` | URL-encoding helper functions |
| `postgresql-pg_graphql` | 1.5.11 | `pg_graphql` | GraphQL over your SQL schema |
| `postgresql-pllua` | 2.0.12 | `pllua` | Lua procedural language |
| `postgresql-tsearch-czech` | 0_git20120119 | Czech FTS dictionary | Czech text-search configuration |

### Not usable with this image

| Alpine package | Why not |
| --- | --- |
| `postgresql-pgmq` | Built against **PostgreSQL 16** and only in the `testing` repo — that is why `pgmq` is compiled from source in the `pgbuilder` stage instead |
| `postgresql-citus` | Built against **PostgreSQL 17** |
| `postgresql-pg_partman`, `postgresql-topn` | No PostgreSQL version pinned — verify with `apk info -R <package>` before use |

> The **extension name can differ from the package name**
> (`postgresql-pgvector` → `vector`, `postgresql-pg_roaringbitmap` →
> `roaringbitmap`). List the real names after installing with the query in
> [Cheat sheet](#cheat-sheet). Verify a package targets PostgreSQL 18 with
> `apk info -R postgresql-<name>` inside the running container.

## Modules that need `shared_preload_libraries`

Libraries listed here must be loaded when the server starts, so the GUC has to be
set **before** PostgreSQL boots. The entrypoint already appends `pg_cron`:

```sh
# docker/entrypoint.sh
shared_preload_libraries = 'pg_cron'
cron.database_name = '<POSTGRES_DB>'
```

To preload more, extend that block:

```sh
shared_preload_libraries = 'pg_cron,pg_stat_statements,timescaledb'
```

| Module | Why it needs preloading |
| --- | --- |
| `pg_cron` | Scheduler background worker — **already configured** |
| `pg_stat_statements` | Shared-memory hash of statement statistics |
| `timescaledb` | Registers its own background workers |
| `login_hook` | Hooks the authentication path |
| `shared_ispell` | Loads dictionaries into shared memory |
| `pg_prewarm` | Optional — only for the autoprewarm worker |

Restart the container after changing it. A restart is also what makes
`pg_cron` / `timescaledb` take effect.

## Postbase-specific caveats

- **Extensions are database-wide.** Installing `pgmq`, `pgvector`, etc. enables
  it for *every* project on the instance. Postbase scopes *usage* of queues and
  cron jobs with the `pb_<projectId>_` prefix, but a type or table is global.
- **`pgvector` — put the `vector` type in the project schema.** The type lands in
  whichever schema the extension is created in, not `public`. Install it into the
  project schema and fully qualify casts inside functions:

  ```sql
  CREATE EXTENSION IF NOT EXISTS vector
    SCHEMA proj_a479764f7ba04fa6aa507303b73c5fa0;

  -- inside an RPC function body
  SELECT 1 - (embedding <=>
              p_embedding::proj_a479764f7ba04fa6aa507303b73c5fa0.vector(1536)) AS similarity
  ```

- **RPC functions**: create them in the **project schema**
  (`proj_<project id with dashes removed>`) and declare them
  `LANGUAGE plpgsql VOLATILE`. Postbase's RPC handler runs `SET` config vars
  before calling the function, which `STABLE`/`IMMUTABLE` functions reject.
- **`search_path`**: if a query cannot see an extension type or function,
  schema-qualify it (`ext_schema.type`).
- **Permissions**: the embedded database user is a **superuser**, so both
  trusted and untrusted extensions can be created. On an **external** database
  the role in `POSTGRES_URL` needs the same rights (and must be able to create
  the `_postbase` / `proj_*` schemas).
- **Version pinning**: the compiled modules are pinned by build args —
  `PGMQ_REF=v1.13.0`, `PG_CRON_REF=v1.6.8`. Override with
  `docker build --build-arg PGMQ_REF=…`.

## Cheat sheet

```sql
-- everything the server can install
SELECT name, default_version, installed_version, comment
FROM pg_available_extensions ORDER BY name;

-- installed extensions and the schema their objects live in
SELECT e.extname, e.extversion, n.nspname
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY 1;

-- is one extension available? installed?
SELECT name, installed_version FROM pg_available_extensions WHERE name = 'pgmq';

-- install / upgrade / remove
CREATE EXTENSION IF NOT EXISTS hstore;
ALTER EXTENSION hstore UPDATE;
DROP EXTENSION hstore;

-- where pgmq / pg_cron objects live
SELECT queue_name FROM pgmq.list_queues() ORDER BY queue_name;
SELECT jobid, schedule, jobname FROM cron.job ORDER BY jobid;
```

### Sources

- Upstream Postbase: `scripts/init.sql` (base extensions), dashboard
  `integrations/page.tsx` and `api/dashboard/[projectId]/queues/route.ts`
  (the two installable modules), `Dockerfile` (upstream compiles the same two
  extensions).
- This repository: `Dockerfile` (`pgbuilder` stage installs `pgmq` — pure SQL, no shared library — and compiles `pg_cron`),
  `docker/entrypoint.sh` (`shared_preload_libraries`).
- Alpine packages for PostgreSQL 18 (`pkgs.alpinelinux.org`, branch v3.23);
  the `pg_config` binary that PGXS needs is provided by the **`postgresql18`** server package — `postgresql18-dev` ships the PGXS makefiles but *not* `pg_config` — so the `pgbuilder` stage installs both.



