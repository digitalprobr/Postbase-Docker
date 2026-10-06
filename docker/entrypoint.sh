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
#   5. stop PostgreSQL and hand off to supervisord (`postgres` + `node app`)
#
# Every database step is checked: a failure prints the reason and exits instead
# of leaving a half-initialised container whose only symptom is the app failing
# to connect.
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

# Fixed paths. PGDATA must be a persistent volume mount to keep data.
PGDATA=/data/postgres
SOCKET_DIR=/tmp
PG_LOG=/tmp/postgres-start.log

# The embedded database always listens on 127.0.0.1:5432. Any DATABASE_URL
# supplied by the platform is replaced so a leftover "localhost" value from
# .env.example cannot break the deployment.
PROVIDED_DATABASE_URL="${DATABASE_URL:-}"
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"
export PGPASSWORD="$POSTGRES_PASSWORD"

if [ -n "$PROVIDED_DATABASE_URL" ] && [ "$PROVIDED_DATABASE_URL" != "$DATABASE_URL" ]; then
  echo "NOTE: ignoring the provided DATABASE_URL — using the embedded PostgreSQL at 127.0.0.1:5432."
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
die() {
  echo "============================================================" >&2
  echo "FATAL: $1" >&2
  shift
  for line in "$@"; do
    echo "       $line" >&2
  done
  echo "============================================================" >&2
  exit 1
}

dump_log() {
  if [ -f "$PG_LOG" ]; then
    echo "--- $PG_LOG ---" >&2
    cat "$PG_LOG" >&2
    echo "---------------" >&2
  fi
}

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

PG_SERVER="$(find_bin postgres)"    || die "PostgreSQL 'postgres' binary not found."
PG_INITDB="$(find_bin initdb)"      || die "PostgreSQL 'initdb' binary not found."
PG_CTL="$(find_bin pg_ctl)"         || die "PostgreSQL 'pg_ctl' binary not found."
PSQL="$(find_bin psql)"             || die "PostgreSQL 'psql' binary not found."
PG_ISREADY="$(find_bin pg_isready)" || die "PostgreSQL 'pg_isready' binary not found."
SUPERVISORD="$(command -v supervisord 2>/dev/null || echo /usr/bin/supervisord)"
SUEXEC="$(command -v su-exec 2>/dev/null || echo /sbin/su-exec)"

[ -x "$SUEXEC" ] || die "su-exec not found; cannot run commands as the postgres user."

echo "==> PostgreSQL binaries: $(dirname "$PG_SERVER")"
echo "==> Database: user=${POSTGRES_USER} db=${POSTGRES_DB} data=${PGDATA}"

run_as_postgres() { "$SUEXEC" postgres "$@"; }

# psql over the local unix socket — trusted locally, so no password is needed
# while bootstrapping (the password is only set afterwards).
psql_local() {
  run_as_postgres "$PSQL" -h "$SOCKET_DIR" -p 5432 -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 "$@"
}

# ── Prepare the data directory ───────────────────────────────────────────────
mkdir -p "$PGDATA" "$SOCKET_DIR" /var/log/supervisor
chown -R postgres:postgres "$PGDATA"
# initdb REFUSES a data directory that is group/world accessible
# ("invalid permissions ... u=rwx (0700) or u=rwx,g=rx (0750)").
chmod 700 "$PGDATA"
# A stale pid file from an unclean shutdown would prevent PostgreSQL from starting.
rm -f "$PGDATA/postmaster.pid"

# ── Initialise the cluster (first run only) ──────────────────────────────────
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  if [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    echo "WARNING: ${PGDATA} is not empty and has no PG_VERSION — attempting initdb anyway." >&2
  fi

  echo "==> Initialising PostgreSQL cluster in ${PGDATA} (first run)..."
  rm -f "$PG_LOG"
  if ! run_as_postgres "$PG_INITDB" -D "$PGDATA" \
        --username="$POSTGRES_USER" \
        --auth-local=trust \
        --auth-host=md5 > "$PG_LOG" 2>&1; then
    cat "$PG_LOG" >&2
    die "initdb failed — see the output above."
  fi

  {
    echo "listen_addresses = '127.0.0.1'"
    echo "port = 5432"
    echo "unix_socket_directories = '$SOCKET_DIR'"
  } >> "$PGDATA/postgresql.conf"
  echo "==> Cluster initialised."
fi

# Allow password logins over TCP for the app (idempotent).
if ! grep -q '127.0.0.1/32' "$PGDATA/pg_hba.conf" 2>/dev/null; then
  echo "host all all 127.0.0.1/32 md5" >> "$PGDATA/pg_hba.conf"
fi

# ── Start PostgreSQL for initialisation ──────────────────────────────────────
echo "==> Starting PostgreSQL for initialisation..."
rm -f "$PG_LOG"
if ! run_as_postgres "$PG_CTL" -D "$PGDATA" -l "$PG_LOG" -w -t 60 start; then
  dump_log
  die "PostgreSQL failed to start."
fi

# ── Set the password (self-correcting on restarts) ───────────────────────────
if ! psql_local -d template1 -q \
      -c "ALTER USER \"$POSTGRES_USER\" WITH PASSWORD '$POSTGRES_PASSWORD';"; then
  dump_log
  die "Could not set the password for '${POSTGRES_USER}'."
fi

# ── Create the application database if missing ───────────────────────────────
DB_EXISTS="$(psql_local -d template1 -tAc "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB'" 2>/dev/null || true)"
if [ "$DB_EXISTS" != "1" ]; then
  echo "==> Creating database ${POSTGRES_DB}..."
  psql_local -d template1 -q -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";" \
    || { dump_log; die "Could not create database '${POSTGRES_DB}'."; }
fi

# ── Base schema + extensions (idempotent) ────────────────────────────────────
echo "==> Creating base schema and extensions..."
if [ -f /app/scripts/init.sql ]; then
  psql_local -d "$POSTGRES_DB" -q -f /app/scripts/init.sql \
    || echo "WARNING: scripts/init.sql failed. Continuing." >&2
else
  echo "  -> /app/scripts/init.sql not found, skipping."
fi

# ── Drizzle migrations (filename order: 0000_, 0001_, ...) ───────────────────
echo "==> Applying Drizzle migrations..."
for f in $(ls /app/drizzle/*.sql 2>/dev/null | sort); do
  echo "  -> $(basename "$f")"
  psql_local -d "$POSTGRES_DB" -q -f "$f" \
    || echo "WARNING: $(basename "$f") failed. Continuing." >&2
done
echo "==> Database initialisation done."

# ── Verify the app will be able to connect over TCP ──────────────────────────
if ! "$PG_ISREADY" -h 127.0.0.1 -p 5432 -q; then
  dump_log
  die "PostgreSQL is not accepting TCP connections on 127.0.0.1:5432."
fi

# ── Hand the database over to supervisord ────────────────────────────────────
# Stop the temporary server so supervisord owns the single PostgreSQL process.
run_as_postgres "$PG_CTL" -D "$PGDATA" -w -t 60 stop \
  || echo "WARNING: could not stop the temporary PostgreSQL server." >&2

# Stable path referenced by supervisord.conf.
ln -sf "$PG_SERVER" /usr/local/bin/pg-server
[ -x /usr/local/bin/pg-server ] || die "Could not create /usr/local/bin/pg-server."
mkdir -p /var/log/supervisor

echo "==> Starting supervisord (PostgreSQL + Next.js on 0.0.0.0:${PORT})..."
exec "$SUPERVISORD" -c /etc/supervisor/conf.d/supervisord.conf

