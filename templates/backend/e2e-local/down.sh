#!/usr/bin/env bash
# Template — scripts/e2e/local/down.sh. Stops what up.sh started, by PID (never by pattern).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
source scripts/e2e/local/env.sh
for pidfile in "$E2E_RUN_DIR"/*.pid; do
  [[ -e "$pidfile" ]] || continue
  pid=$(cat "$pidfile")
  if [[ "$(basename "$pidfile")" == redis.pid && "${E2E_KEEP_REDIS:-1}" == 1 ]]; then continue; fi
  kill "$pid" 2>/dev/null && echo "stopped $(basename "$pidfile" .pid) ($pid)"
  rm -f "$pidfile"
done
