# ─────────────────────────────────────────────────────────────────────────────
# Postbase — self-contained app image (Next.js standalone build)
#
# Self-hosted deploy per https://www.getpostbase.com/docs/deploy-docker
#
# This image does NOT require the Postbase source to live in this repository:
# the builder stage clones the upstream project (harshalone/postbase) and builds
# it from there. Override the source with build args if you want a fork/tag:
#   docker build --build-arg POSTBASE_REF=v0.3.16 -t postbase-app .
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

EXPOSE 3000

CMD ["node", "apps/web/server.js"]
