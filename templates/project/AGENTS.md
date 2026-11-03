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
| Binary / image | `<app>` / image repository `<project>-prod-app` |
| Services | `<project>-prod-api` (main) and `<project>-prod-worker` (worker) |
| Database | `<db>`; application through the pooler's transaction endpoint `<host:port>`, migrations/psql through the session endpoint `<host:port>`; last migration in production: `NNN` |
| Domain | `<domain>` (web), `api.<domain>`, `cdn.<domain>` (public files), `internal.<domain>` (dashboard) |
| Logs | `<log group/stream of the API>`, `<log group/stream of the worker>` |

### 1.1 Providers (this project's choices)

Pakem leaves products and services to the project ([`docs/blueprint/00-principles.md`](docs/blueprint/00-principles.md)
§F 22). Record each choice next to the requirement it meets; change a row when the choice changes. A filled-in example is
pakem's case study (`case-studies/aws-supabase-cloudflare`).

| Role | Requirement (blueprint) | Product / service | Account, region, names |
|---|---|---|---|
| Cloud & container platform | one image as two services, rollout settings, circuit breaker (08 §4.2) | `<…>` | account `<…>`, CLI profile `<profile>` (always pass it), region `<region>` |
| CPU architecture | the image is built for it, on a native runner (08 §5) | `<amd64 / arm64>` | |
| Image registry | one repository, tags `latest` + `<short_sha>` (08 §6) | `<…>` | `<project>-prod-app` |
| Load balancer & edge | TLS end to end, accepts only the edge (08 §4.3, 09 §1) | `<…>` | |
| Postgres | managed or self-hosted, behind a transaction-mode pooler (02 §6) | `<…>` | `<db>`, endpoints above |
| Redis | single node, ≥ 6.2 (04 §1) | `<…>` | |
| Search engine | private, persistent data, one pinned version (05 §4) | `<…>` | version `<x.y>` |
| Object storage | S3 API, public + private buckets (09 §4) | `<…>` | `<public-bucket>`, `<private-bucket>` |
| Frontend hosting & edge function | Git-push deploys, functions only where needed (09 §2–§3) | `<…>` | `<site names>`, `<edge names>` |
| DNS | proxied API record, email records (09 §1) | `<…>` | zone `<domain>` |
| Email | a provider API, domain authenticated (05 §3.5) | `<…>` | sender `no-reply@<domain>` |
| Logs & error tracker store | queryable log store; conditional writes (06) | `<…>` | |
| Secret store | names in the infra repo, values injected at start (08 §3.2) | `<…>` | prefix `/<project>/prod` |
| Infrastructure as code & CI | plan on PR, apply on `main`, federated credentials (08 §2) | `<…>` | |

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
   observability 06, testing 07, infrastructure 08, frontend & storage 09, workflow 10, checklists 11).
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

- **BE:** merge into `master` (a direct merge commit, no PR unless asked), push `origin`, then `<deploy command>`
  and monitor until both services are stable and run the new digest (blueprint 08 §6.2).
- **FE / dashboard:** merge into the production branch, push `origin` — `<static host>` deploys on its own.
- **edge:** `<edge deploy command, tagged with the SHA>` from the branch that is in sync.
- **mobile:** merge into `develop`, push `origin`. **Never** trigger the app store release workflow.
- **infra:** push to `main` = CI apply = service redeploy if a service definition changes.

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

- DB & Redis always local; `JWT_API_SECRET` dummy; the search engine through Docker, one container per session, bound to
  `127.0.0.1`.
- Production object storage and OAuth providers may be used only for entities/accounts created by the testing session.
- Message & money sender credentials (payment gateway, messaging, email, push) are **not** copied to the local env.
- Production dump for local testing: `<path-dump>` (restore into a new local DB; contains PII — do not share it,
  empty the integration tokens before starting the server).
- Every job that changes files: a worktree + new branch at `~/worktrees/<repo>/<branch-without-slash>` from
  `origin/<main-branch>` (blueprint 10).

## 9. Deviations from the blueprint

| Topic | Project decision | Reason | Date |
|---|---|---|---|
| — | — | — | — |
