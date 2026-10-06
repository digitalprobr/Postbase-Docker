# postbase (deploy)

Deployment wrapper for **[Postbase](https://www.getpostbase.com/docs/deploy-docker)** — the self-hosted auth + database platform for Next.js.

This repository deliberately contains **no application source**. Its `Dockerfile` clones the upstream project ([`harshalone/postbase`](https://github.com/harshalone/postbase)) at build time and produces a small runtime image. That keeps this repo to a few files and makes it trivial to redeploy / bump versions.

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build. Clones upstream, runs `pnpm install` + `pnpm --filter web build`, ships the Next.js **standalone** server. |
| `docker/entrypoint.sh` | Container entrypoint: waits for Postgres, applies `scripts/init.sql` + `apps/web/drizzle/*.sql`, then starts the server. |
| `docker-compose.yml` | Local stack: PostgreSQL 18 + the app (ports `5432` and `3000`). |
| `.env.example` | Template for all required/optional environment variables. |

## How the image is built

The builder stage:

1. clones the upstream monorepo (`--depth 1`) into `/app`,
2. installs the pnpm workspace from the committed lockfile (`pnpm install --frozen-lockfile`),
3. builds the web app (`pnpm --filter web build`) which emits `apps/web/.next/standalone`.

The runtime stage only contains the standalone server + static assets and runs:

```
node apps/web/server.js
```

on `0.0.0.0:3000`.

Source selection is configurable via build args:

| Build arg | Default | Description |
| --- | --- | --- |
| `POSTBASE_REPO` | `https://github.com/harshalone/postbase.git` | Git repository to clone. |
| `POSTBASE_REF` | `main` | Branch or tag to build. |

### Startup / database initialization

The container **starts the web server immediately** so orchestrator healthchecks (Coolify/Docker) pass, then initializes the database **in the background**:

1. waits until PostgreSQL accepts connections (up to `DB_WAIT_RETRIES × DB_WAIT_INTERVAL` seconds),
2. applies `scripts/init.sql` — creates the `_postbase` schema and the `uuid-ossp` / `pgcrypto` extensions,
3. applies every `apps/web/drizzle/*.sql` migration in filename order.

Initialization is **best-effort**: failures are logged but never stop the server, and the server never blocks on the database. If the database is unreachable the app still runs (API/dashboard calls fail until it is fixed) — restart the container afterwards to run initialization. Re-applying already-run migrations is tolerated (existing objects error and are skipped). For a clean re-init, drop the database/volume and redeploy.

## Deploy on Coolify

1. Create an **Application** resource pointing at this repo (`main` branch).
2. Build pack: **Dockerfile** (path: `Dockerfile`). Port: **3000**.
3. Add a **PostgreSQL** database resource and link it to this application (Coolify then injects `DATABASE_URL`), and set the environment variables:

   | Variable | Required | Notes |
   | --- | --- | --- |
   | `DATABASE_URL` | ✅ | Connection string to your Postgres resource. |
   | `NEXTAUTH_SECRET` | ✅ | `openssl rand -base64 32` |
   | `NEXTAUTH_URL` | ✅ | Public URL, e.g. `https://<your-app-domain>` |
   | `POSTBASE_JWT_SECRET` | ➖ | Recommended. `openssl rand -base64 32` |

4. Deploy. The entrypoint waits for Postgres and initializes the schema + migrations automatically (see below).

To pin a specific release, pass a build arg, e.g. `POSTBASE_REF=v0.3.16`.

## Local development / self-hosted with Docker Compose

```bash
cp .env.example .env          # then set NEXTAUTH_SECRET (openssl rand -base64 32)
docker compose up -d          # PostgreSQL :5432 + app :3000
# Initialize the database (see below), then open:
#   http://localhost:3000/dashboard
```

Useful commands:

```bash
docker compose logs -f app      # tail the app logs
docker compose down             # stop (data preserved in the postgres_data volume)
docker compose down -v          # stop and wipe the database
```

### Build the image directly

```bash
docker build -t postbase-app .
docker run -p 3000:3000 \
  -e DATABASE_URL="postgresql://postbase:postbase@host:5432/postbase" \
  -e NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  -e NEXTAUTH_URL="http://localhost:3000" \
  postbase-app
```

## Database initialization (automatic)

The app requires the internal `_postbase` schema and its tables to exist. This is done for you on container start:

- `scripts/init.sql` runs first (schema + extensions),
- then `apps/web/drizzle/*.sql` migrations run in order.

Both files are taken from the cloned upstream source at build time — nothing to run manually.

**Manual fallback** (e.g. a database that the container cannot reach, or a hosted Postgres you prefer to prepare yourself):

```sql
CREATE SCHEMA IF NOT EXISTS _postbase;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
```

```bash
git clone --depth 1 https://github.com/harshalone/postbase.git
cd postbase/apps/web
pnpm install
DATABASE_URL="postgresql://..." pnpm db:push     # push the schema directly
```

> `pg_cron` and `pgmq` are optional; install them from the dashboard's Integrations page if needed.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql://postbase:postbase@localhost:5432/postbase` | PostgreSQL connection string. Inside Compose it points at the `postgres` service. |
| `POSTGRES_USER` | `postbase` | Compose only — Postgres superuser. |
| `POSTGRES_PASSWORD` | `postbase` | Compose only — Postgres password. |
| `POSTGRES_DB` | `postbase` | Compose only — database name. |
| `POSTGRES_PORT` | `5432` | Compose only — host port for Postgres. |
| `APP_PORT` | `3000` | Compose only — host port for the app. |
| `NEXTAUTH_SECRET` | — | **Required.** Signs Auth.js sessions/tokens. |
| `NEXTAUTH_URL` | `http://localhost:3000` | Public URL of this instance. |
| `POSTBASE_JWT_SECRET` | — | Signs Postbase API JWTs. |
| `DB_WAIT_RETRIES` | `60` | Entrypoint: max attempts to reach Postgres before giving up on init. |
| `DB_WAIT_INTERVAL` | `2` | Entrypoint: seconds between connection attempts. |

## Notes & caveats

- **Migrations run automatically** on container start via `docker/entrypoint.sh` (see above); failures are logged but never block startup.
- Building requires **network access** to clone the upstream repository at build time.
- The image is built from upstream `main` by default. Bump `POSTBASE_REF` to upgrade deliberately.
- Data lives in the `postgres_data` volume — back it up, and note `docker compose down -v` deletes it.

## Links

- Docs: https://www.getpostbase.com/docs/deploy-docker
- Upstream project: https://github.com/harshalone/postbase

## License

This deployment wrapper is provided as-is. The bundled Postbase software is licensed under the MIT License (see the upstream repository).
