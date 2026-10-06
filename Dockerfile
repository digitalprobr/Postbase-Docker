# ─────────────────────────────────────────────────────────────────────────────
# Postbase — app image (Next.js standalone build)
#
# Self-hosted deploy per https://www.getpostbase.com/docs/deploy-docker
#
# Build context MUST be the monorepo root (this folder), e.g.:
#   docker build -t postbase-app .
# or via docker compose (see docker-compose.yml).
#
# Assumes the standard Postbase monorepo layout:
#   package.json, pnpm-lock.yaml, pnpm-workspace.yaml
#   apps/web/package.json
#   apps/web/.next/standalone   (requires `output: "standalone"` in next.config)
# ─────────────────────────────────────────────────────────────────────────────

# ─── Base ─────────────────────────────────────────────────────────────────────
FROM node:22-alpine AS base
RUN npm install -g pnpm
WORKDIR /app


# ─── Deps ─────────────────────────────────────────────────────────────────────
FROM base AS deps
# Manifests first so the dependency layer is cached independently of source.
COPY package.json pnpm-workspace.yaml* pnpm-lock.yaml* ./
COPY apps/web/package.json ./apps/web/
RUN pnpm install --frozen-lockfile


# ─── Builder ──────────────────────────────────────────────────────────────────
FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/web/node_modules ./apps/web/node_modules
COPY . .
RUN pnpm --filter web build


# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
# Standalone server binds to localhost by default — must be 0.0.0.0 in Docker.
ENV HOSTNAME=0.0.0.0

# Next.js standalone output + static assets + public files
COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/public ./apps/web/public

EXPOSE 3000

CMD ["node", "apps/web/server.js"]
