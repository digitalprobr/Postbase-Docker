#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Postbase container entrypoint
#
#   1. wait for PostgreSQL to accept connections
#   2. apply scripts/init.sql          (schema + extensions)
#   3. apply apps/web/drizzle/*.sql     (migrations, in filename order)
#   4. start the Next.js standalone server
#
# Deliberately NOT using `set -e`: a migration hiccup must not prevent the web
# server from starting. Otherwise an orchestrator healthcheck sees a container
# that never listens and the whole deploy loops.
# ─────────────────────────────────────────────────────────────────────────────
set -u

PORT="${PORT:-3000}"
export PORT

DB_WAIT_RETRIES="${DB_WAIT_RETRIES:-30}"
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-2}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL is not set. Point it at your PostgreSQL instance." >&2
  exit 1
fi

# ── Wait for PostgreSQL ───────────────────────────────────────────────────────
echo "==> Waiting for database to become reachable..."
db_ready=0
attempt=1
while [ "$attempt" -le "$DB_WAIT_RETRIES" ]; do
  if psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1; then
    db_ready=1
    echo "==> Database is reachable (attempt ${attempt})."
    break
  fi
  echo "  -> not ready yet (attempt ${attempt}/${DB_WAIT_RETRIES}), retrying in ${DB_WAIT_INTERVAL}s..."
  attempt=$((attempt + 1))
  sleep "$DB_WAIT_INTERVAL"
done

if [ "$db_ready" -ne 1 ]; then
  echo "WARNING: database not reachable after retries. Starting the server anyway;" >&2
  echo "         the API will report errors until the database is up." >&2
fi

# ── Apply a single .sql file (failures are logged, not fatal) ─────────────────
apply_sql() {
  file="$1"
  echo "  -> applying $(basename "$file")"
  if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$file"; then
    echo "WARNING: '$(basename "$file")' failed. Continuing so the server can still start." >&2
  fi
}

# ── Initialize the database ───────────────────────────────────────────────────
if [ "$db_ready" -eq 1 ]; then
  echo "==> Creating base schema and extensions..."
  if [ -f /app/scripts/init.sql ]; then
    apply_sql /app/scripts/init.sql
  else
    echo "  -> /app/scripts/init.sql not found, skipping."
  fi

  if [ -d /app/drizzle ]; then
    echo "==> Applying Drizzle migrations..."
    # `ls | sort` preserves migration order (0000_, 0001_, ...).
    for f in $(ls /app/drizzle/*.sql 2>/dev/null | sort); do
      apply_sql "$f"
    done
  fi
  echo "==> Database initialization done."
else
  echo "==> Skipping database initialization (database was not reachable)."
fi

# ── Start Next.js ────────────────────────────────────────────────────────────
# HOSTNAME=0.0.0.0 is required — the standalone server binds to localhost by
# default, which a container proxy cannot reach.
echo "==> Starting Next.js server on 0.0.0.0:${PORT}..."
exec env HOSTNAME=0.0.0.0 node /app/apps/web/server.js
