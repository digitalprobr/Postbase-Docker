# postbase (deploy)

Deployment wrapper for **[Postbase](https://www.getpostbase.com/docs/deploy-docker)** — the self-hosted auth + database platform for Next.js.

This repository deliberately contains **no application source**. Its `Dockerfile` clones the upstream project ([`harshalone/postbase`](https://github.com/harshalone/postbase)) at build time and produces a small runtime image. That keeps this repo to a few files and makes it trivial to redeploy / bump versions.

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build. Clones upstream, runs `pnpm install` + `pnpm --filter web build`, ships the Next.js **standalone** server. |
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

## Deploy on Coolify

1. Create an **Application** resource pointing at this repo (`main` branch).
2. Build pack: **Dockerfile** (path: `Dockerfile`). Port: **3000**.
3. Add a **PostgreSQL** database resource and link it, then set the environment variables:

   | Variable | Required | Notes |
   | --- | --- | --- |
   | `DATABASE_URL` | ✅ | Connection string to your Postgres resource. |
   | `NEXTAUTH_SECRET` | ✅ | `openssl rand -base64 32` |
   | `NEXTAUTH_URL` | ✅ | Public URL, e.g. `https://<your-app-domain>` |
   | `POSTBASE_JWT_SECRET` | ➖ | Recommended. `openssl rand -base64 32` |

4. Deploy.
5. **Initialize the database** (see below) — the container serves the app but does not create the schema itself.

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

## Required: initialize the database

The app expects the internal `_postbase` schema and extensions to already exist. Run this against your database once (e.g. Coolify's Postgres terminal, `psql`, or Drizzle Studio):

```sql
CREATE SCHEMA IF NOT EXISTS _postbase;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
```

Then apply the Drizzle migrations. The easiest way is against a checkout of the upstream project:

```bash
git clone --depth 1 https://github.com/harshalone/postbase.git
cd postbase/apps/web
pnpm install
DATABASE_URL="postgresql://..." pnpm db:push     # push the schema
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

## Notes & caveats

- **Migrations are not run automatically.** The container only starts the web server; apply the schema/migrations as described above.
- Building requires **network access** to clone the upstream repository at build time.
- The image is built from upstream `main` by default. Bump `POSTBASE_REF` to upgrade deliberately.
- Data lives in the `postgres_data` volume — back it up, and note `docker compose down -v` deletes it.

## Links

- Docs: https://www.getpostbase.com/docs/deploy-docker
- Upstream project: https://github.com/harshalone/postbase

## License

This deployment wrapper is provided as-is. The bundled Postbase software is licensed under the MIT License (see the upstream repository).
