# Template — scripts/e2e/local/env.sh. Shared settings for the local e2e scripts; env can override every one.
# EVERYTHING IS LOCAL: never point this at a remote database or Redis.
: "${E2E_APP:=app}"                     # binary/application name (replace per project)
: "${E2E_DB:=${E2E_APP}_e2e}"
: "${E2E_PGHOST:=/var/run/postgresql}"   # socket directory or host; peer/trust auth
: "${E2E_PGPORT:=5432}"
: "${E2E_PGUSER:=$(id -un)}"
: "${E2E_PORT:=8001}"                    # API; Fiber listens on 0.0.0.0, so stop it after the run
: "${E2E_REDIS_PORT:=6390}"              # e2e's own redis-server, no persistence
: "${E2E_RUN_DIR:=$(git rev-parse --show-toplevel)/.e2e}"
: "${E2E_PSQL:=psql}"

export E2E_APP E2E_DB E2E_PGHOST E2E_PGPORT E2E_PGUSER E2E_PORT E2E_REDIS_PORT E2E_RUN_DIR
# Optional fake ports (empty = not started): third-party stand-ins in scripts/e2e/fake*/
export E2E_FAKE_OAUTH_PORT="${E2E_FAKE_OAUTH_PORT:-}"
export E2E_FAKE_S3_PORT="${E2E_FAKE_S3_PORT:-}"   # object storage (S3 API)
export PGHOST="$E2E_PGHOST" PGPORT="$E2E_PGPORT" PGUSER="$E2E_PGUSER"
