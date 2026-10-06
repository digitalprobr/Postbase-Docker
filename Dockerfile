# ─────────────────────────────────────────────────────────────────────────────
# Postbase — self-contained app image (Next.js standalone build)
#
# Self-hosted deploy per https://www.getpostbase.com/docs/deploy-docker
#
# This image does NOT require the Postbase source to live in this repository:
# the builder stage clones the upstream project (harshalone/postbase) and builds
# it from there. Override the source with build args if you want a fork/tag:
#   docker build --build-arg POSTBASE_REF=v0.3.16 -t postbase-app .
#
# At runtime, docker/entrypoint.sh waits for PostgreSQL and applies
# scripts/init.sql + apps/web/drizzle/*.sql before starting the server.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Base ─────────────────────────────────────────────────────────────────────
FROM node:22-alpine AS base
# git is needed to clone the upstream source; ca-certificates for HTTPS.
RUN apk add --no-cache git ca-certificates \
    && npm install -g pnpm@9
ENV NEXT_TELEMETRY_DISABLED=1
WORKDIR /app

# Upstream source location (overridable at build time).
ARG POSTBASE_REPO=https://github.com/harshalone/postbase.git
ARG POSTBASE_REF=main


# ─── Builder ──────────────────────────────────────────────────────────────────
FROM base AS builder
# 1. Fetch the upstream monorepo (pnpm workspace: apps/web).
RUN git clone --depth 1 --branch "${POSTBASE_REF}" "${POSTBASE_REPO}" .
# 2. Install workspace dependencies from the committed lockfile.
RUN pnpm install --frozen-lockfile
# 3. Produce the Next.js standalone build (apps/web/.next/standalone).
RUN pnpm --filter web build


# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM node:22-alpine AS runner
# psql (postgresql-client) is used by the entrypoint to wait for the database
# and to apply the schema + migrations on startup. curl is used by Coolify's
# container healthcheck.
RUN apk add --no-cache postgresql-client curl
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV NEXT_TELEMETRY_DISABLED=1
# Standalone server binds to localhost by default — must be 0.0.0.0 in Docker.
ENV HOSTNAME=0.0.0.0

# Next.js standalone output + static assets + public files
COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/public ./apps/web/public

# SQL applied on startup: base schema/extensions + Drizzle migrations
COPY --from=builder /app/scripts /app/scripts
COPY --from=builder /app/apps/web/drizzle /app/drizzle

# Entrypoint: wait for Postgres → initialize schema/migrations → start the server
COPY docker/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
