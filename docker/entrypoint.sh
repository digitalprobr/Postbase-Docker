#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Postbase container entrypoint
#
#   1. wait for PostgreSQL to accept connections (bounded)
#   2. apply scripts/init.sql          (schema + extensions)
#   3. apply apps/web/drizzle/*.sql     (migrations, in filename order)
#   4. start the Next.js standalone server
#
# These steps run BEFORE the server starts: Postbase's Next.js instrumentation
# hook queries _postbase.cron_jobs during boot, so the app aborts (and nothing
# listens on :3000) if the database/schema is not ready.
#
# The wait is bounded so a missing/unreachable database cannot blow past the
# orchestrator healthcheck window (Coolify: 5s start period + 10 x 5s ~= 55s).
# ─────────────────────────────────────────────────────────────────────────────
set -u

PORT="${PORT:-3000}"
export PORT

DB_WAIT_RETRIES="${DB_WAIT_RETRIES:-20}"   # 20 x 2s = 40s max, under Coolify's window
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-2}"

# ── Apply a single .sql file (failures are logged, not fatal) ─────────────────
apply_sql() {
  file="$1"
  echo "  -> applying $(basename "$file")"
  if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$file"; then
    echo "WARNING: '$(basename "$file")' failed. Continuing." >&2
  fi
}

# ── Validate DATABASE_URL ─────────────────────────────────────────────────────
db_configured=0
if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL is not set — the database cannot be initialized." >&2
  echo "       Link a PostgreSQL resource in Coolify (it injects DATABASE_URL)." >&2
else
  db_configured=1
  case "$DATABASE_URL" in
    *@localhost:*|*@127.0.0.1:*)
      echo "ERROR: DATABASE_URL points at localhost/127.0.0.1." >&2
      echo "       Inside this container that is the app itself, not your database." >&2
      echo "       Use the Postgres service hostname, e.g. postgresql://user:pass@postgres:5432/postbase" >&2
      ;;
  esac
fi

# ── Initialize the database ───────────────────────────────────────────────────
if [ "$db_configured" -eq 1 ]; then
  echo "==> Waiting for database to become reachable..."
  db_ready=0
  attempt=1
  while [ "$attempt" -le "$DB_WAIT_RETRIES" ]; do
    if psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1; then
      db_ready=1
      echo "==> Database is reachable (attempt ${attempt})."
      break
    fi
    if [ $((attempt % 5)) -eq 0 ]; then
      echo "  -> still waiting (attempt ${attempt}/${DB_WAIT_RETRIES})..."
    fi
    attempt=$((attempt + 1))
    sleep "$DB_WAIT_INTERVAL"
  done

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
    echo "WARNING: database not reachable after ${DB_WAIT_RETRIES} attempts." >&2
    echo "         Starting the server anyway; it will not be healthy until DATABASE_URL is fixed." >&2
  fi
fi

# ── Start Next.js ────────────────────────────────────────────────────────────
# HOSTNAME=0.0.0.0 is required — the standalone server binds to localhost by
# default, which a container proxy cannot reach.
echo "==> Starting Next.js server on 0.0.0.0:${PORT}..."
exec env HOSTNAME=0.0.0.0 node /app/apps/web/server.js
