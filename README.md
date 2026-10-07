# postbase (deploy)

All-in-one deployment for **[Postbase](https://www.getpostbase.com/docs/deploy-docker)** — the self-hosted auth + database platform for Next.js.

One image runs **PostgreSQL 18 + the Next.js app** together, so by default there is **no external database to configure** — or point it at **your own PostgreSQL** with a single environment variable (`POSTGRES_URL`). The Postbase source is cloned at build time, so this repository stays tiny.

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Stage 1 clones and builds the Next.js **standalone** app; stage 2 adds PostgreSQL 18, `supervisor` and the app. |
| `docker/entrypoint.sh` | Initialises the embedded cluster, runs `scripts/init.sql` + Drizzle migrations, then hands off to supervisord. |
| `docker/supervisord.conf` | Supervises the `postgres` and `node` processes. |
| `docker-compose.yml` | Local run: one service + a `/data` volume. |
| `.env.example` | Template for database credentials and secrets. |

## How the image works

**Build stage** — clones the upstream monorepo (`--depth 1`), `pnpm install --frozen-lockfile`, `pnpm --filter web build`, producing `apps/web/.next/standalone`.

**Runtime stage** — `node:22-alpine` + `postgresql18`, `supervisor`, `su-exec`, `curl`.

On start, `docker/entrypoint.sh`:

1. locates the PostgreSQL binaries (Alpine puts them in `/usr/libexec/postgresql18`),
2. `initdb`s `/data/postgres` — **first run only**,
3. starts PostgreSQL, sets `POSTGRES_PASSWORD`, creates `POSTGRES_DB`,
4. applies `scripts/init.sql` (schema + `uuid-ossp`/`pgcrypto`) and every `apps/web/drizzle/*.sql` in filename order,
5. stops the temporary server and `exec`s supervisord, which keeps PostgreSQL (priority 10) and the app (priority 20) running.

Migrations run **before** the app starts, because Postbase's Next.js instrumentation hook queries `_postbase.cron_jobs` at boot.

> The entrypoint selects the database mode automatically. With no `POSTGRES_URL`/`DATABASE_URL` (or one pointing at loopback) it runs the **embedded** PostgreSQL and derives `DATABASE_URL` as `postgresql://<POSTGRES_USER>:<POSTGRES_PASSWORD>@127.0.0.1:5432/<POSTGRES_DB>` — this is what makes the stack immune to a leftover `localhost` value. Point `POSTGRES_URL` at a reachable host to run in **external** mode instead.

Source selection is configurable via build args:

| Build arg | Default | Description |
| --- | --- | --- |
| `POSTBASE_REPO` | `https://github.com/harshalone/postbase.git` | Git repository to clone. |
| `POSTBASE_REF` | `main` | Branch or tag to build. |

## Using your own PostgreSQL (external database)

The image ships with PostgreSQL, but you can point it at **your own** database — no rebuild needed, just set one variable:

```env
POSTGRES_URL="postgresql://<user>:<password>@<host>:5432/<database>"
```

When `POSTGRES_URL` (or `DATABASE_URL`) targets a **non-loopback host**, the entrypoint switches to external mode:

1. skips `initdb` and never starts the embedded server,
2. waits until your PostgreSQL accepts connections (`pg_isready`),
3. applies `scripts/init.sql`, every `drizzle/*.sql` and the idempotent schema patches to **your** database,
4. runs the app directly (`node apps/web/server.js`) — supervisord is not used.

The `/data` volume is then unused (and harmless).

> ⚠️ **`127.0.0.1` does not reach your host from inside a container** — it is the container itself. A loopback `POSTGRES_URL` keeps using the **embedded** database (a note is logged). To reach a server on the Docker host use `host.docker.internal` (`docker compose` already adds the `extra_hosts: ["host.docker.internal:host-gateway"]` mapping); for a server elsewhere use its real hostname or IP.

Example `.env` for a PostgreSQL running on the Docker host:

```env
POSTGRES_URL="postgresql://postbase:secret@host.docker.internal:5432/postbase"
NEXTAUTH_SECRET="..."
NEXTAUTH_URL="http://localhost:3000"
```

The user/database that `POSTGRES_URL` points at must already **exist**; use a role allowed to create tables, extensions and the `_postbase`/`proj_*` schemas (a superuser is simplest).

## Deploy on Coolify

1. Create an **Application** resource pointing at this repo (`main` branch).
2. Build pack: **Dockerfile** (path: `Dockerfile`). Port: **3000**.
3. Set the environment variables:

   | Variable | Required | Notes |
   | --- | --- | --- |
   | `NEXTAUTH_SECRET` | ✅ | `openssl rand -base64 32` |
   | `NEXTAUTH_URL` | ✅ | Your public URL, e.g. `https://my-postbase.example.com` |
   | `POSTBASE_JWT_SECRET` | ➖ | Recommended. `openssl rand -base64 32` |
   | `POSTGRES_URL` | ➖ | Set it to use **your own** PostgreSQL instead of the embedded one (see *Using your own PostgreSQL*). |
   | `POSTGRES_PASSWORD` | ➖ | Embedded mode only. Change from the `postbase` default for production. |
   | `POSTGRES_USER`, `POSTGRES_DB` | ➖ | Embedded mode only. Defaults to `postbase`. |

   > By default you do **not** need a database resource and do **not** need to set `DATABASE_URL`. Set `POSTGRES_URL` only if you want to use an external database.

4. **Add a persistent volume** (recommended): application → *Persistent Storages* → add a volume with destination **`/data`**. Without it, PostgreSQL data is recreated on every deploy.
5. Deploy, then open `/setup` to create the admin account.

To pin a release, pass a build arg, e.g. `POSTBASE_REF=v0.3.16`.

## Local / self-hosted with Docker Compose

```bash
cp .env.example .env          # then set NEXTAUTH_SECRET (openssl rand -base64 32)
docker compose up -d          # app + embedded PostgreSQL on :3000
# open http://localhost:3000/setup
```

```bash
docker compose logs -f app      # tail logs
docker compose down             # stop (data kept in the postbase_data volume)
docker compose down -v          # stop and wipe the database
```

### Build the image directly

```bash
docker build -t postbase .
docker run -p 3000:3000 \
  -v postbase_data:/data \
  -e NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  -e NEXTAUTH_URL="http://localhost:3000" \
  postbase
```

## API documentation (Swagger)

Open **`/docs`** for the Swagger UI. It renders **`/docs/openapi.json`**, which is
built on every request from two sources:

1. the REST endpoints the app is annotated with (`@swagger` JSDoc in
   `apps/web/src/app/api/**`), and
2. the **live database**, introspected automatically — one component schema per
   table of every project schema (`proj_*`), with the real columns and types.

How it is wired (all owned by this repo, so no upstream changes are needed):

| Path | Role |
| --- | --- |
| `docker/web-override/apps/web/src/app/docs/page.tsx` | The `/docs` page (Swagger UI). |
| `docker/web-override/apps/web/src/app/docs/openapi.json/route.ts` | Serves `/docs/openapi.json`. |
| `docker/web-override/apps/web/src/app/mcp/route.ts` | The MCP server at `/mcp` (Streamable HTTP), auto-generated from the spec. |
| `docker/web-override/apps/web/src/lib/openapi-spec.ts` | Shared spec builder used by `/docs/openapi.json` **and** `/mcp`. |
| `docker/web-override/apps/web/src/lib/openapi-from-db.ts` | Introspects PostgreSQL → OpenAPI schemas. |
| `docker/web-override/apps/web/scripts/generate-openapi.mjs` | Build-time: freezes the REST spec from the `@swagger` comments. |

The overlay is copied over the upstream clone in the build stage, and
`generate-openapi.mjs` runs **before** `next build`. This is required because the
standalone image ships no `src/` sources, so upstream's runtime `next-swagger-doc`
scan (used by the built-in `/docs/api`) has nothing to read in production; `/docs`
instead reads the frozen JSON and adds the database schemas at runtime.

> `/docs/api` (upstream) is left untouched; `/docs` is the supported entry point.

## MCP endpoint (`/mcp`)

Postbase also exposes an **MCP server at `/mcp`**, auto-generated from the same
OpenAPI document as `/docs`. It "detects" the Swagger spec (the `@swagger` REST
endpoints **plus** the live `proj_*` tables) and turns every operation into a
callable MCP tool. There are **no extra dependencies**: the JSON-RPC 2.0 /
Streamable-HTTP layer lives in the overlay.

| MCP method | Behaviour |
| --- | --- |
| `initialize` | Returns server info, capabilities and usage instructions. |
| `tools/list` | One tool per OpenAPI operation (e.g. `post_api_db_query`, `post_api_db_sql`, `post_api_rpc`). |
| `tools/call` | Runs the operation by proxying to this instance's own REST API. |
| `ping`, `resources/list`, `prompts/list` | Handled; resources and prompts are empty. |

Point an MCP client at the Streamable-HTTP URL:

```json
{
  "mcpServers": {
    "postbase": {
      "url": "https://my-postbase.example.com/mcp",
      "headers": { "Authorization": "Bearer pb_anon_REPLACE_ME" }
    }
  }
}
```

**Authentication** — send the Postbase key as `Authorization: Bearer pb_anon_…`
(respects Row Level Security) or `pb_service_…` (bypasses RLS). Optionally add
`X-Postbase-Token: <user JWT>` to run a tool as a specific end user. The key and
headers are forwarded to the underlying endpoint, so **RLS and project scoping
behave exactly as in a direct API call**.

`tools/call` only ever calls paths that exist in the OpenAPI document, so there
is no way to reach an arbitrary URL through `/mcp`.

Optional: set `POSTBASE_MCP_BASE_URL` if the app cannot reach itself at the
default `http://127.0.0.1:$PORT` when proxying tool calls.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `POSTGRES_URL` | — | Your own PostgreSQL (`postgresql://user:pass@host:5432/db`). A **non-loopback host** switches the image to external mode. |
| `DATABASE_URL` | — | Fallback used when `POSTGRES_URL` is unset (same rules). |
| `POSTGRES_USER` | `postbase` | **Embedded mode only.** Superuser created in the embedded cluster. |
| `POSTGRES_PASSWORD` | `postbase` | **Embedded mode only.** Password for that user (kept in sync on every start). |
| `POSTGRES_DB` | `postbase` | **Embedded mode only.** Application database, created if missing. |
| `PORT` | `3000` | Port the Next.js server binds to. |
| `APP_PORT` | `3000` | Compose only — host port for the app. |
| `NEXTAUTH_SECRET` | — | **Required.** Signs Auth.js sessions/tokens. |
| `NEXTAUTH_URL` | `http://localhost:3000` | Public URL of this instance. |
| `POSTBASE_JWT_SECRET` | — | Signs Postbase API JWTs. |
| `POSTBASE_MCP_BASE_URL` | `http://127.0.0.1:$PORT` | Base URL `/mcp` uses to call this instance's own REST API. |

## Notes & caveats

- **The entrypoint fails loudly.** Every database step is checked; a failure prints a `FATAL:` block with the reason (and PostgreSQL's own log) and exits, instead of leaving a container whose only symptom is the app failing to connect. Check the container logs (`docker logs` / Coolify → *Logs*).
- **Schema patches are applied after migrations.** The Drizzle migrations in the repo are older than the application schema (e.g. `_postbase.projects.user_column_defs` has no migration), so an idempotent patch step mirrors upstream's Railway entrypoint. Without it the dashboard fails with `column "user_column_defs" does not exist`.
- **Data lives at `/data/postgres`** in embedded mode. Mount a persistent volume at `/data` or your database is recreated on each deploy. In external mode your data lives in your own PostgreSQL and the volume is irrelevant.
- **External mode needs a reachable host.** `127.0.0.1` inside the container is the container itself; use `host.docker.internal` for a database on the Docker host.
- **Single instance only.** The embedded PostgreSQL is not designed for horizontal scaling or multiple replicas.
- **First boot is slower** (~15-25s) because `initdb` runs; later boots take a few seconds.
- **No `pg_cron` / `pgmq`.** Postbase's cron jobs use `node-cron`; install the optional extensions from the dashboard's Integrations page if you need them.
- **Building requires network access** to clone the upstream repository.
- **Migrations are replayed on every start** and are idempotent (`IF NOT EXISTS`); already-existing objects log warnings that are safely ignored.
- The admin account is **not** seeded — it is created on first visit to `/setup`.

## Links

- Docs: https://www.getpostbase.com/docs/deploy-docker
- Upstream project: https://github.com/harshalone/postbase

## License

This deployment wrapper is provided as-is. The bundled Postbase software is licensed under the MIT License (see the upstream repository).
