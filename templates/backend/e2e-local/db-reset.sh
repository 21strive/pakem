#!/usr/bin/env bash
# Template — scripts/e2e/local/db-reset.sh.
# Recreates the e2e database: the production schema (a snapshot without rows), every numbered migration
# after that snapshot, then the reference rows (seed.sql). Flushes the e2e Redis if it is running.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source scripts/e2e/local/env.sh

# Snapshot = the production schema at migration SCHEMA_LEVEL (pg_dump --schema-only, no owner/ACL).
# Every later migration runs, in order, so a new migration is picked up automatically.
SCHEMA=scripts/e2e/local/schema_prod_YYYYMMDD_postNNN.sql   # replace: production schema snapshot file
SCHEMA_LEVEL=0                                             # replace: last migration number in the snapshot

dropdb --if-exists "$E2E_DB"
createdb "$E2E_DB"
$E2E_PSQL -q -v ON_ERROR_STOP=1 -d "$E2E_DB" -f "$SCHEMA" >/dev/null
# One psql per file, autocommit: DO NOT use -1 / --single-transaction. A migration that builds an index
# CONCURRENTLY cannot run inside a transaction block — exactly as in production.
for f in migrations/[0-9][0-9][0-9]_*.sql; do
  n=$((10#$(basename "$f" | cut -c1-3)))
  if (( n > SCHEMA_LEVEL )); then
    $E2E_PSQL -q -v ON_ERROR_STOP=1 -d "$E2E_DB" -f "$f" >/dev/null
    echo "migrated $(basename "$f")"
  fi
done
# Reference data only (fee configuration, templates, holidays, system accounts) — no customer data.
$E2E_PSQL -q -v ON_ERROR_STOP=1 -d "$E2E_DB" -f scripts/e2e/local/seed.sql >/dev/null

if redis-cli -p "$E2E_REDIS_PORT" ping >/dev/null 2>&1; then
  redis-cli -p "$E2E_REDIS_PORT" flushall >/dev/null
  echo "flushed redis :$E2E_REDIS_PORT"
fi
rm -rf "$E2E_RUN_DIR/email"
echo "database $E2E_DB ready"
