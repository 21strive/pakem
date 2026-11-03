#!/usr/bin/env bash
# Template — scripts/e2e/local/up.sh.
# Builds the binary and runs it in the background: the API on :$E2E_PORT and the workers the suite needs,
# against the e2e database and e2e's own Redis. Logs and pids go to $E2E_RUN_DIR; down.sh stops them.
#
# The .env is GENERATED in $E2E_RUN_DIR (never .env.local/.env.staging, which point at remote hosts).
# The contents of $E2E_RUN_DIR/env.extra (if present) are appended at the end — the place for e.g. the search engine's
# env or a payment gateway stand-in.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source scripts/e2e/local/env.sh

mkdir -p "$E2E_RUN_DIR/email"
scripts/e2e/local/down.sh >/dev/null 2>&1 || true

if ! redis-cli -p "$E2E_REDIS_PORT" ping >/dev/null 2>&1; then
  redis-server --port "$E2E_REDIS_PORT" --bind 127.0.0.1 --save '' --appendonly no \
    --daemonize yes --pidfile "$E2E_RUN_DIR/redis.pid" --logfile "$E2E_RUN_DIR/redis.log"
fi

go build -o "$E2E_RUN_DIR/$E2E_APP" ./app/cmd
[[ -n "$E2E_FAKE_OAUTH_PORT" ]] && (cd scripts/e2e && go build -o "$E2E_RUN_DIR/fakeoauth" ./fakeoauth)
[[ -n "$E2E_FAKE_S3_PORT" ]] && (cd scripts/e2e && go build -o "$E2E_RUN_DIR/fakes3" ./fakes3)

# Dummy password: an empty password makes libpq swallow the next DSN keyword (dbname); peer/trust auth
# ignores it. Local Postgres runs without TLS. Pool sizes = production, so burst tests hit
# the same limits (the default of 100 per pool exceeds the local Postgres max_connections).
cat > "$E2E_RUN_DIR/.env" <<ENV
ENVIRONMENT=local
PORT=$E2E_PORT
API_PUBLIC_BASE_URL=http://127.0.0.1:$E2E_PORT
POSTGRES_WRITE_HOST=$E2E_PGHOST
POSTGRES_WRITE_PORT=$E2E_PGPORT
POSTGRES_WRITE_USERNAME=$E2E_PGUSER
POSTGRES_WRITE_PASSWORD=e2e
POSTGRES_WRITE_DBNAME=$E2E_DB
POSTGRES_READ_HOST=$E2E_PGHOST
POSTGRES_READ_PORT=$E2E_PGPORT
POSTGRES_READ_USERNAME=$E2E_PGUSER
POSTGRES_READ_PASSWORD=e2e
POSTGRES_READ_DBNAME=$E2E_DB
POSTGRES_SSLMODE=disable
POSTGRES_WRITE_MAX_OPEN_CONNS=10
POSTGRES_READ_MAX_OPEN_CONNS=10
REDIS_ADDR=127.0.0.1:$E2E_REDIS_PORT
JWT_API_SECRET=e2e-local-not-a-secret
EMAIL_SINK_DIR=$E2E_RUN_DIR/email
WHATSAPP_ENABLED=false
PUSH_ENABLED=false
ENV
# Object storage → the in-memory S3 stand-in. Rename the keys to the project's own config names.
if [[ -n "$E2E_FAKE_S3_PORT" ]]; then
  fake="http://127.0.0.1:$E2E_FAKE_S3_PORT"
  cat >> "$E2E_RUN_DIR/.env" <<ENV
STORAGE_ENDPOINT=$fake
STORAGE_BUCKET=${E2E_APP}-e2e
STORAGE_REGION=local
STORAGE_ACCESS_KEY_ID=fake-s3
STORAGE_SECRET_ACCESS_KEY=fake-s3
ASSET_PUBLIC_BASE_URL=$fake/${E2E_APP}-e2e
ENV
fi
[[ -f "$E2E_RUN_DIR/env.extra" ]] && cat "$E2E_RUN_DIR/env.extra" >> "$E2E_RUN_DIR/.env"

start() { # name, args... (fakes run their own binary)
  local name=$1; shift
  local binary="./$E2E_APP"
  [[ "$name" == fake* ]] && binary=./$name
  (cd "$E2E_RUN_DIR" && exec "$binary" "$@") > "$E2E_RUN_DIR/$name.log" 2>&1 &
  echo $! > "$E2E_RUN_DIR/$name.pid"
}
[[ -n "$E2E_FAKE_OAUTH_PORT" ]] && start fakeoauth -addr "127.0.0.1:$E2E_FAKE_OAUTH_PORT"
[[ -n "$E2E_FAKE_S3_PORT" ]] && start fakes3 -addr "127.0.0.1:$E2E_FAKE_S3_PORT"
start server main
start worker-notification worker notification
for name in ${E2E_EXTRA_WORKERS:-}; do start "worker-$name" worker "$name"; done

for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:$E2E_PORT/health"; then
    echo "api up on http://127.0.0.1:$E2E_PORT (logs in $E2E_RUN_DIR)"
    exit 0
  fi
  if ! kill -0 "$(cat "$E2E_RUN_DIR/server.pid")" 2>/dev/null; then
    tail -20 "$E2E_RUN_DIR/server.log"; exit 1
  fi
  sleep 1
done
echo "api did not come up"; tail -20 "$E2E_RUN_DIR/server.log"; exit 1
