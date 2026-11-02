# Template — backend repo Makefile. The e2e targets use scripts/e2e/local (see templates/backend/e2e-local).

# Swagger (requires: go install github.com/swaggo/swag/cmd/swag@latest)
gen-swagger:
	swag fmt
	swag init -g ./app/cmd/main.go -o ./app/specs

clean:
	go mod tidy
	go mod download

run:
	go run -race ./app/cmd "main"

# Worker — runs until SIGINT/SIGTERM. No name = every worker in one process.
run-worker:
	go run -race ./app/cmd "worker"

# One target per named worker, with a one-line comment: what it does and how often.
# Example:
# Sends the notifications queued in notification_outbox.
run-worker-notification:
	go run -race ./app/cmd "worker" "notification"

# One-off command: make run-command CMD=<name> ARGS="--dry-run"
run-command:
	go run ./app/cmd "command" "$(CMD)" $(ARGS)

test:
	go test ./...

arch:
	go test ./app -run TestArchitecture

# Local E2E (scripts/e2e/local; local PostgreSQL + redis-server on this machine).
#   make e2e-db-reset && make e2e-up && make e2e && make e2e-down
e2e-db-reset:
	scripts/e2e/local/db-reset.sh

e2e-up:
	scripts/e2e/local/up.sh

e2e-down:
	scripts/e2e/local/down.sh

# E2E_ARGS passes flags to go test, e.g. E2E_ARGS='-run TestWidget'.
e2e:
	. scripts/e2e/local/env.sh && cd scripts/e2e && \
	E2E_BASE_URL=$${E2E_BASE_URL:-http://127.0.0.1:$$E2E_PORT} \
	E2E_DATABASE_URL=$${E2E_DATABASE_URL:-"host=$$E2E_PGHOST port=$$E2E_PGPORT dbname=$$E2E_DB sslmode=disable"} \
	E2E_EMAIL_SINK_DIR=$${E2E_EMAIL_SINK_DIR:-$$E2E_RUN_DIR/email} \
	go test -v -count=1 $(E2E_ARGS) ./...

.PHONY: gen-swagger clean run run-worker run-worker-notification run-command test arch e2e-db-reset e2e-up e2e-down e2e
