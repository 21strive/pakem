# AGENTS.md — <project> backend

> Template from `pakem/templates/project/AGENTS.md`. Copy it to the root of the new project's backend repo,
> replace every `<…>`, delete this quote block. The root `CLAUDE.md` contains one line: `see @AGENTS.md`.

The **<Product>** backend: one Go binary (Fiber HTTP + worker + command) with read/write PostgreSQL as the only
source of truth and Redis as the cache (library `redifu`). This repo follows **pakem** (the backend blueprint), copied into
[`docs/blueprint/`](docs/blueprint/) (blueprint commit `<sha>`). The blueprint rules apply in full except where listed
in §9 "Deviations from the blueprint".

## 1. Project identity

| Item | Value |
|---|---|
| Go module | `github.com/<org>/<app>` |
| Binary / image | `<app>` / ECR `<project>-prod-app` |
| AWS | dedicated project account, CLI profile `<profile>` (always `--profile <profile>`), region `<region>` |
| ECS | cluster `<project>-prod-cluster`, services `<project>-prod-api` (main) and `<project>-prod-worker` (worker) |
| Database | Supabase `<db>` through the pooler (application :6543 transaction, migrations/psql :5432 session); last migration in production: `NNN` |
| Redis | Redis Cloud, single node, ≥ 6.2 |
| Domain | `<domain>` (web), `api.<domain>`, `cdn.<domain>` (public R2), `internal.<domain>` (dashboard) |
| Cloudflare | Pages `<project>-fe-main` / `-staging`, `internal-dashboard`; Worker `<project>-edge-main` / `-staging`; R2 `<public-bucket>`, `<private-bucket>` |
| Logs | CloudWatch `/ecs/<project>-prod/api`, `/ecs/<project>-prod/worker` |

## 2. Repo aliases

| Alias | Repo | Main branch | Local path |
|---|---|---|---|
| **BE** | `<org>/<repo-be>` | `master` | `~/<repo-be>` |
| **FE** / web | `<org>/<repo-web>` | `main` | `~/<repo-web>` |
| **dashboard** | `<org>/<repo-dashboard>` | `master` | `~/<repo-dashboard>` |
| **mobile** | `<org>/<repo-mobile>` | `develop` | `~/<repo-mobile>` |
| **infra** | `<org>/<project>-prod-infra` | `main` | `~/<project>-prod-infra` |
| **edge** | `<org>/<project>-edge` | `staging` + `main` (in sync) | `~/<project>-edge` |

## 3. Read first

1. [`docs/blueprint/00-principles.md`](docs/blueprint/00-principles.md) — the core principles.
2. The blueprint document for your task's topic (architecture 01, database 02, endpoints 03, caching 04, workers 05,
   observability 06, testing 07, AWS 08, Cloudflare 09, workflow 10, checklists 11).
3. This repo's `docs/reference/` — today's truth for the project's domain (including `docs/reference/platform/redifu.md`
   for the list of cached views).

## 4. Commands

```bash
make run                                   # HTTP server
make run-worker                            # all workers
make run-command CMD=<name> ARGS="--dry-run"
make gen-swagger && mockery                # after changing controller annotations / interfaces
go test ./...                              # all tests (architecture test included)
make e2e-db-reset && make e2e-up && make e2e && make e2e-down   # local E2E
CGO_ENABLED=0 GOOS=linux go build -o ./<app> ./app/cmd
```

## 5. Architecture (short — details in blueprint 01)

> Route picks the handler, Middleware authenticates, Controller orchestrates, Validator parses, UseCase decides
> and runs the transaction, Repository stores (its decorator reads from the cache) — Provider assembles it all once.

- Controllers/middleware never call a repository. Only `app/responses` maps error kinds to HTTP.
- Every resource from client input is checked in the usecase to belong to the caller; does not exist == not yours
  (the same 404).
- Every entity has its initiator `New<Entity>()` (allocates it, calls `redifu.InitRecord`); a new instance is created
  only through it, never as an inline struct literal; rows read from the DB are scanned, never `New…()`.
- Writes never touch Redis; the cache follows through trigger → `redifu_outbox` → drain. Everything the cache stores
  embeds `*redifu.Record`.
- Outgoing side effects (email, WA, push, third-party APIs) go through an outbox table + worker, not inside the
  transaction.
- Every new endpoint: Swagger (`make gen-swagger`) **and** the Postman collection in `app/specs/`.

## 6. Deploy

If the user says **deploy**, it means, per repo:

- **BE:** merge into `master` (a direct merge commit, no PR unless asked), push `origin`, then
  `gh workflow run deploy.yml --ref master` and monitor until the rollout is `COMPLETED` (blueprint 08 §6.2).
- **FE / dashboard:** merge into the production branch, push `origin` — Cloudflare Pages deploys on its own.
- **edge:** `npx wrangler deploy --env main --tag <sha>` from the branch that is in sync.
- **mobile:** merge into `develop`, push `origin`. **Never** trigger the app store release workflow.
- **infra:** push to `main` = CI apply = service redeploy if the task definition changes.

Cross-repo order: production migrations (with approval) → BE until finished → web/dashboard/mobile → feature switch.
Take the deploy lock if there are several sessions (blueprint 10).

## 7. Production

- The BE production env is at `<path-env-production>`; any command that uses it touches production. Do not
  print secret values.
- **Production migrations/backfills/data changes require the user's approval in that session**, unless the user has
  already given blanket approval for non-destructive migrations. Anything that deletes/overwrites data is always asked
  about (blueprint 02).
- There is no backend staging: local validation (E2E + dump copy), then a staged rollout with feature switches.

## 8. Local environment

- DB & Redis always local; `JWT_API_SECRET` dummy; local Typesense through Docker per session, bound to `127.0.0.1`.
- Production R2/Google/Zoom may be used only for entities/accounts created by the testing session.
- Message & money sender credentials (payment gateway, WhatsApp, SES, FCM) are **not** copied to the local env.
- Production dump for local testing: `<path-dump>` (restore into a new local DB; contains PII — do not share it,
  empty the integration tokens before starting the server).
- Every job that changes files: a worktree + new branch at `~/worktrees/<repo>/<branch-without-slash>` from
  `origin/<main-branch>` (blueprint 10).

## 9. Deviations from the blueprint

| Topic | Project decision | Reason | Date |
|---|---|---|---|
| — | — | — | — |
