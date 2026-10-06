#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Postbase container entrypoint
#
# The web server is started IMMEDIATELY so orchestrator healthchecks (Coolify,
# Docker, Kubernetes) pass. Database initialization then runs in the
# background:
#
#   1. wait for PostgreSQL to accept connections
#   2. apply scripts/init.sql          (schema + extensions)
#   3. apply apps/web/drizzle/*.sql     (migrations, in filename order)
#
# Initialization is best-effort: failures are logged, never fatal, and never
# delay the server from listening on 0.0.0.0:$PORT.
# ─────────────────────────────────────────────────────────────────────────────
set -u

PORT="${PORT:-3000}"
export PORT

DB_WAIT_RETRIES="${DB_WAIT_RETRIES:-60}"
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-2}"

# ── Apply a single .sql file (failures are logged, not fatal) ─────────────────
apply_sql() {
  file="$1"
  echo "  -> applying $(basename "$file")"
  if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$file"; then
    echo "WARNING: '$(basename "$file")' failed. Continuing." >&2
  fi
}

# ── Database initialization (runs in the background) ──────────────────────────
init_db() {
  echo "==> [db-init] waiting for database to become reachable..."
  db_ready=0
  attempt=1
  while [ "$attempt" -le "$DB_WAIT_RETRIES" ]; do
    if psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1; then
      db_ready=1
      echo "==> [db-init] database is reachable (attempt ${attempt})."
      break
    fi
    # Log sparsely so a slow/absent database does not flood the logs.
    if [ $((attempt % 10)) -eq 0 ]; then
      echo "  -> [db-init] still waiting (attempt ${attempt}/${DB_WAIT_RETRIES})..."
    fi
    attempt=$((attempt + 1))
    sleep "$DB_WAIT_INTERVAL"
  done

  if [ "$db_ready" -ne 1 ]; then
    echo "WARNING: [db-init] database not reachable after ${DB_WAIT_RETRIES} attempts." >&2
    echo "         Skipping initialization. Restart the container once it is up." >&2
    return 0
  fi

  echo "==> [db-init] creating base schema and extensions..."
  if [ -f /app/scripts/init.sql ]; then
    apply_sql /app/scripts/init.sql
  else
    echo "  -> /app/scripts/init.sql not found, skipping."
  fi

  if [ -d /app/drizzle ]; then
    echo "==> [db-init] applying Drizzle migrations..."
    # `ls | sort` preserves migration order (0000_, 0001_, ...).
    for f in $(ls /app/drizzle/*.sql 2>/dev/null | sort); do
      apply_sql "$f"
    done
  fi

  echo "==> [db-init] done."
}

if [ -n "${DATABASE_URL:-}" ]; then
  init_db &
else
  echo "WARNING: DATABASE_URL is not set — skipping database initialization." >&2
  echo "         Link a Postgres resource (or set DATABASE_URL) and restart." >&2
fi

# ── Start Next.js immediately ────────────────────────────────────────────────
# HOSTNAME=0.0.0.0 is required — the standalone server binds to localhost by
# default, which a container proxy cannot reach.
echo "==> Starting Next.js server on 0.0.0.0:${PORT}..."
exec env HOSTNAME=0.0.0.0 node /app/apps/web/server.js
