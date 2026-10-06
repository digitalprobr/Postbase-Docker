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


# ─── Stage 2: all-in-one runtime (PostgreSQL + app) ──────────────────────────
FROM node:22-alpine AS runner

# postgresql18  → the embedded database server (creates the `postgres` user)
# supervisor    → runs postgres + the app together
# su-exec       → drop privileges when setting up the cluster as `postgres`
# curl          → used by Coolify's container healthcheck
RUN apk add --no-cache postgresql18 postgresql18-client postgresql-common \
                       supervisor su-exec curl

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
