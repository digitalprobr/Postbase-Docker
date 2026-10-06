#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Postbase all-in-one container entrypoint
#
# PostgreSQL 18 and the Next.js app live in the SAME container, so no external
# database is needed. On start:
#
#   1. locate the PostgreSQL server binaries
#   2. initialise the cluster in /data/postgres (first run only)
#   3. start PostgreSQL, set the password, create the database
#   4. apply scripts/init.sql + apps/web/drizzle/*.sql
#   5. stop PostgreSQL and hand off to supervisord (which supervises
#      `postgres` + `node app`)
#
# Migrations run before the app starts because Postbase's Next.js
# instrumentation hook queries _postbase.cron_jobs during boot.
# ─────────────────────────────────────────────────────────────────────────────
set -u

POSTGRES_USER="${POSTGRES_USER:-postbase}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postbase}"
POSTGRES_DB="${POSTGRES_DB:-postbase}"
PORT="${PORT:-3000}"
export PORT

# The embedded database always listens on 127.0.0.1:5432. Any DATABASE_URL
# supplied by the platform is replaced so a leftover "localhost" value from
# .env.example cannot break the deployment.
PGDATA=/data/postgres
PROVIDED_DATABASE_URL="${DATABASE_URL:-}"
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"
export PGPASSWORD="$POSTGRES_PASSWORD"

if [ -n "$PROVIDED_DATABASE_URL" ] && [ "$PROVIDED_DATABASE_URL" != "$DATABASE_URL" ]; then
  echo "NOTE: ignoring the provided DATABASE_URL — using the embedded PostgreSQL at 127.0.0.1:5432."
fi

# ── Locate the PostgreSQL binaries ───────────────────────────────────────────
# Their location depends on the Alpine package layout.
find_bin() {
  for dir in /usr/libexec/postgresql18 /usr/lib/postgresql18/bin /usr/lib/postgresql/18/bin /usr/bin; do
    if [ -x "$dir/$1" ]; then
      echo "$dir/$1"
      return 0
    fi
  done
  return 1
}

PG_SERVER="$(find_bin postgres)" || { echo "FATAL: PostgreSQL 'postgres' binary not found." >&2; exit 1; }
PG_INITDB="$(find_bin initdb)"   || { echo "FATAL: PostgreSQL 'initdb' binary not found."   >&2; exit 1; }
PG_CTL="$(find_bin pg_ctl)"      || { echo "FATAL: PostgreSQL 'pg_ctl' binary not found."   >&2; exit 1; }
PSQL="$(find_bin psql)"          || { echo "FATAL: PostgreSQL 'psql' binary not found."     >&2; exit 1; }
SUPERVISORD="$(command -v supervisord 2>/dev/null || echo /usr/bin/supervisord)"
SUEXEC="$(command -v su-exec 2>/dev/null || echo /sbin/su-exec)"

echo "==> PostgreSQL binaries: $(dirname "$PG_SERVER")"
echo "==> Database: user=${POSTGRES_USER} db=${POSTGRES_DB} data=${PGDATA}"

run_as_postgres() { "$SUEXEC" postgres "$@"; }

# ── Prepare the data directory ───────────────────────────────────────────────
mkdir -p "$PGDATA" /var/log/supervisor
chown -R postgres:postgres "$PGDATA"
# Stale pid file from an unclean shutdown would prevent PostgreSQL from starting.
rm -f "$PGDATA/postmaster.pid"

# ── Initialise the cluster (first run only) ──────────────────────────────────
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "==> Initialising PostgreSQL cluster in ${PGDATA} (first run)..."
  run_as_postgres "$PG_INITDB" -D "$PGDATA" \
    --username="$POSTGRES_USER" \
    --auth-local=trust \
    --auth-host=md5
  {
    echo "listen_addresses = '127.0.0.1'"
    echo "port = 5432"
  } >> "$PGDATA/postgresql.conf"
fi

# Allow password logins over TCP (idempotent).
if ! grep -q '127.0.0.1/32' "$PGDATA/pg_hba.conf" 2>/dev/null; then
  echo "host all all 127.0.0.1/32 md5" >> "$PGDATA/pg_hba.conf"
fi

# ── Start PostgreSQL for initialisation ──────────────────────────────────────
echo "==> Starting PostgreSQL for initialisation..."
run_as_postgres "$PG_CTL" -D "$PGDATA" -w -t 60 start

# Keep the password in sync with POSTGRES_PASSWORD (self-correcting on restarts).
"$PSQL" -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d template1 -v ON_ERROR_STOP=1 -q \
  -c "ALTER USER \"$POSTGRES_USER\" WITH PASSWORD '$POSTGRES_PASSWORD';"

# Create the application database if it does not exist yet.
DB_EXISTS="$("$PSQL" -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d template1 -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB'")"
if [ "$DB_EXISTS" != "1" ]; then
  echo "==> Creating database ${POSTGRES_DB}..."
  "$PSQL" -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d template1 -v ON_ERROR_STOP=1 -q \
    -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"
fi

# ── Base schema + extensions (idempotent) ────────────────────────────────────
echo "==> Creating base schema and extensions..."
if [ -f /app/scripts/init.sql ]; then
  "$PSQL" -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q \
    -f /app/scripts/init.sql \
    || echo "WARNING: scripts/init.sql failed. Continuing." >&2
else
  echo "  -> /app/scripts/init.sql not found, skipping."
fi

# ── Drizzle migrations (filename order: 0000_, 0001_, ...) ───────────────────
echo "==> Applying Drizzle migrations..."
for f in $(ls /app/drizzle/*.sql 2>/dev/null | sort); do
  echo "  -> $(basename "$f")"
  "$PSQL" -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -f "$f" \
    || echo "WARNING: $(basename "$f") failed. Continuing." >&2
done
echo "==> Database initialisation done."

# ── Hand the database over to supervisord ────────────────────────────────────
# Stop the temporary server so supervisord owns the single PostgreSQL process.
run_as_postgres "$PG_CTL" -D "$PGDATA" -w -t 60 stop
# Symlink with a stable name referenced by supervisord.conf.
ln -sf "$PG_SERVER" /usr/local/bin/pg-server
mkdir -p /var/log/supervisor

echo "==> Starting supervisord (PostgreSQL + Next.js on 0.0.0.0:${PORT})..."
exec "$SUPERVISORD" -c /etc/supervisor/conf.d/supervisord.conf
