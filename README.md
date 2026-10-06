# postbase (deploy)

All-in-one deployment for **[Postbase](https://www.getpostbase.com/docs/deploy-docker)** — the self-hosted auth + database platform for Next.js.

One container runs **PostgreSQL 18 + the Next.js app** together, so there is **no external database to configure**. The Postbase source is cloned at build time, so this repository stays tiny.

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

> `DATABASE_URL` is derived inside the container as `postgresql://<POSTGRES_USER>:<POSTGRES_PASSWORD>@127.0.0.1:5432/<POSTGRES_DB>`. Any `DATABASE_URL` you set is ignored (a note is logged) — this is what makes the stack immune to a leftover `localhost` value.

Source selection is configurable via build args:

| Build arg | Default | Description |
| --- | --- | --- |
| `POSTBASE_REPO` | `https://github.com/harshalone/postbase.git` | Git repository to clone. |
| `POSTBASE_REF` | `main` | Branch or tag to build. |

## Deploy on Coolify

1. Create an **Application** resource pointing at this repo (`main` branch).
2. Build pack: **Dockerfile** (path: `Dockerfile`). Port: **3000**.
3. Set the environment variables:

   | Variable | Required | Notes |
   | --- | --- | --- |
   | `NEXTAUTH_SECRET` | ✅ | `openssl rand -base64 32` |
   | `NEXTAUTH_URL` | ✅ | Your public URL, e.g. `https://my-postbase.example.com` |
   | `POSTBASE_JWT_SECRET` | ➖ | Recommended. `openssl rand -base64 32` |
   | `POSTGRES_PASSWORD` | ➖ | Change from the `postbase` default for production. |
   | `POSTGRES_USER`, `POSTGRES_DB` | ➖ | Defaults to `postbase`. |

   > You do **not** need a database resource, and you do **not** need to set `DATABASE_URL`.

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

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `POSTGRES_USER` | `postbase` | Superuser created in the embedded cluster. |
| `POSTGRES_PASSWORD` | `postbase` | Password for that user (kept in sync on every start). |
| `POSTGRES_DB` | `postbase` | Application database, created if missing. |
| `PORT` | `3000` | Port the Next.js server binds to. |
| `APP_PORT` | `3000` | Compose only — host port for the app. |
| `NEXTAUTH_SECRET` | — | **Required.** Signs Auth.js sessions/tokens. |
| `NEXTAUTH_URL` | `http://localhost:3000` | Public URL of this instance. |
| `POSTBASE_JWT_SECRET` | — | Signs Postbase API JWTs. |

## Notes & caveats

- **The entrypoint fails loudly.** Every database step is checked; a failure prints a `FATAL:` block with the reason (and PostgreSQL's own log) and exits, instead of leaving a container whose only symptom is the app failing to connect. Check the container logs (`docker logs` / Coolify → *Logs*).
- **Data lives at `/data/postgres`.** Mount a persistent volume at `/data` or your database is recreated on each deploy.
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
