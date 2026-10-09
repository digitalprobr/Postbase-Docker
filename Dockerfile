# ─────────────────────────────────────────────────────────────────────────────
# Postbase — all-in-one image (PostgreSQL 18 + Next.js standalone in one container)
#
# Self-hosted deploy per https://www.getpostbase.com/docs/deploy-docker
#
# PostgreSQL runs INSIDE this container and the app connects to it over
# 127.0.0.1:5432, so no external database is required. The data directory is
# /data/postgres — mount a persistent volume at /data to keep your data.
#
# The Postbase source is cloned at build time, so this repository stays tiny:
#   docker build --build-arg POSTBASE_REF=v0.3.16 -t postbase .
# ─────────────────────────────────────────────────────────────────────────────

# ─── Stage 1: build the Next.js app ──────────────────────────────────────────
FROM node:22-alpine AS builder
# git is needed to clone the upstream source; ca-certificates for HTTPS.
RUN apk add --no-cache git ca-certificates \
    && npm install -g pnpm@9
ENV NEXT_TELEMETRY_DISABLED=1
WORKDIR /app

# Upstream source location (overridable at build time).
ARG POSTBASE_REPO=https://github.com/harshalone/postbase.git
ARG POSTBASE_REF=main

# 1. Fetch the upstream monorepo (pnpm workspace: apps/web).
RUN git clone --depth 1 --branch "${POSTBASE_REF}" "${POSTBASE_REPO}" .
# 2. Install workspace dependencies from the committed lockfile.
RUN pnpm install --frozen-lockfile
# 3. Overlay the Swagger /docs route, the /mcp MCP endpoint and the OpenAPI
#    generator owned by this repo. (Upstream ships a partial Swagger UI at
#    /docs/api; we add /docs, a serverless-safe /docs/openapi.json and /mcp.)
COPY docker/web-override/apps/web/ /app/apps/web/
# 4. Freeze the REST part of the spec from the @swagger JSDoc in src/app/api
#    while the sources are still present (they are NOT shipped at runtime).
RUN cd /app/apps/web && node scripts/generate-openapi.mjs
# 5. Produce the Next.js standalone build (apps/web/.next/standalone).
RUN pnpm --filter web build


# ─── Stage 2: compile the optional PostgreSQL extensions (pgmq + pg_cron) ────
# The Alpine repositories ship no pgmq build for PostgreSQL 18 (the only pgmq
# package there targets PostgreSQL 16) and pg_cron is version-locked elsewhere,
# so both are compiled from source against the SAME PostgreSQL 18 the runtime
# uses. Building on the same base image guarantees the musl/ICU ABI of the
# resulting .so files matches the server that will load them.
FROM node:22-alpine AS pgbuilder

# build-base       → gcc/make toolchain
# git              → fetch the extension sources
# postgresql18-dev → server headers + the PGXS makefiles
# postgresql18     → the `pg_config` binary. Alpine splits the PostgreSQL 18
#                    server this way: postgresql18-dev ships the PGXS makefiles
#                    but NOT pg_config, so without the server package
#                    $(PG_CONFIG) expands to nothing and make dies with
#                    "No rule to make target 'install'".
# libpq-dev        → pg_cron links against libpq
ARG PGMQ_REF=v1.13.0
ARG PG_CRON_REF=v1.6.8

RUN apk add --no-cache build-base git postgresql18 postgresql18-dev libpq-dev

# pg_config's path depends on the Alpine package split, so it is resolved here
# instead of being hardcoded: /usr/libexec/postgresql18/pg_config, or
# /usr/bin/pg_config (a symlink pointing into it). The discovered binary is
# exposed as `pg_config` on PATH for the PGXS builds below, and a missing one
# fails early with a clear message instead of a cryptic make error.
RUN REAL_PG_CONFIG="$(command -v pg_config || ls /usr/libexec/postgresql*/pg_config 2>/dev/null | head -n 1 || true)" \
    && [ -n "${REAL_PG_CONFIG}" ] && [ -x "${REAL_PG_CONFIG}" ] \
    && echo "pg_config: ${REAL_PG_CONFIG} ($("${REAL_PG_CONFIG}" --version))" \
    && ln -sf "${REAL_PG_CONFIG}" /usr/local/bin/pg_config \
    || { echo "ERROR: pg_config not found — the postgresql18 package must be installed for PGXS builds." >&2; exit 1; }

RUN git clone --depth 1 --branch "${PGMQ_REF}" https://github.com/pgmq/pgmq.git /tmp/pgmq \
    && cd /tmp/pgmq/pgmq-extension \
    && make PG_CONFIG=pg_config \
    && make install PG_CONFIG=pg_config \
    && rm -rf /tmp/pgmq

RUN git clone --depth 1 --branch "${PG_CRON_REF}" https://github.com/citusdata/pg_cron.git /tmp/pg_cron \
    && cd /tmp/pg_cron \
    && make PG_CONFIG=pg_config \
    && make install PG_CONFIG=pg_config \
    && rm -rf /tmp/pg_cron


# ─── Stage 3: all-in-one runtime (PostgreSQL + app) ──────────────────────────
FROM node:22-alpine AS runner

# postgresql18         → the embedded database server (creates the `postgres` user)
# postgresql18-contrib → pgcrypto, uuid-ossp, pg_trgm, hstore, … (used by init.sql)
# supervisor           → runs postgres + the app together
# su-exec              → drop privileges when setting up the cluster as `postgres`
# curl                 → used by Coolify's container healthcheck
RUN apk add --no-cache postgresql18 postgresql18-client postgresql18-contrib postgresql-common \
                       supervisor su-exec curl

# The optional extensions built in stage 2, copied into the same directories
# Alpine's own extensions use, so CREATE EXTENSION finds them and the dashboard's
# Integrations page can enable them.
# pgmq is a pure PL/pgSQL extension: PGXS installs only pgmq.control plus the
# sql/pgmq--*.sql scripts — there is NO pgmq.so to copy.
# pg_cron is a C module and does ship pg_cron.so, which must be copied.
COPY --from=pgbuilder /usr/lib/postgresql18/pg_cron.so /usr/lib/postgresql18/
COPY --from=pgbuilder /usr/share/postgresql18/extension/pgmq*    /usr/share/postgresql18/extension/
COPY --from=pgbuilder /usr/share/postgresql18/extension/pg_cron* /usr/share/postgresql18/extension/

WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0

# Next.js standalone output + static assets + public files
COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/public ./apps/web/public

# SQL applied on first start: base schema/extensions + Drizzle migrations
COPY --from=builder /app/scripts /app/scripts
COPY --from=builder /app/apps/web/drizzle /app/drizzle

# Process supervisor (postgres + app) and the entrypoint
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# PostgreSQL data directory — mount a persistent volume here to keep data.
RUN mkdir -p /data/postgres /var/log/supervisor

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
