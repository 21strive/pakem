# AGENTS.md — pakem

Guidance for agents (Claude Code, etc.) that **build or maintain a backend in the pakem format**: a Go monolith
(Fiber HTTP + workers + commands) on AWS ECS, PostgreSQL (Supabase) as the only source of truth, Redis as a cache through
`redifu`, Typesense for search, and the frontend and object storage on Cloudflare.

This repo is a **universal agreement**: decisions already made and proven in production, written as rules. A
project's `AGENTS.md` (created from [templates/project/AGENTS.md](templates/project/AGENTS.md)) overrides this document
**only** for what it records in its "Deviations from the blueprint" section.

---

## 0. How to use this repo

1. **Read [docs/00-principles.md](docs/00-principles.md) first** — the 30 core decisions that shape every other document.
2. Before working on a topic, read its document:

| Task | Read |
|---|---|
| Code structure, layers, DI, naming | [docs/01-architecture.md](docs/01-architecture.md) |
| Tables, migrations, backfills, DB connections | [docs/02-database.md](docs/02-database.md) |
| Endpoints, response/error contract, auth, security, client handoff | [docs/03-api-design.md](docs/03-api-design.md) |
| Cache & every use of Redis | [docs/04-caching.md](docs/04-caching.md) |
| Workers, commands, outbox, notifications, search, third parties | [docs/05-workers-and-integrations.md](docs/05-workers-and-integrations.md) |
| Logs, error tracker, metrics, latency | [docs/06-observability.md](docs/06-observability.md) |
| Unit tests, guard tests, local E2E, regression | [docs/07-testing-and-e2e.md](docs/07-testing-and-e2e.md) |
| Terraform, ECS, deploy, rollback | [docs/08-aws-infrastructure.md](docs/08-aws-infrastructure.md) |
| Pages, edge Worker, R2, DNS | [docs/09-cloudflare.md](docs/09-cloudflare.md) |
| Git, docs, releases, production, agent sessions | [docs/10-workflow.md](docs/10-workflow.md) |
| Checklists | [docs/11-checklists.md](docs/11-checklists.md) |

3. Copy from [templates/](templates/) instead of writing from scratch: `backend/` (Dockerfile, Makefile, deploy.yml,
   E2E stack, SQL for migrations/outbox/cache), `infra/` (Terraform CI, `prod.tfvars.example`), `docs/` (plan, handoff,
   runbook, backfill, CHANGELOG entry), `session/` (COMMON, HANDOFF, E2E, RELEASE), `project/AGENTS.md`.
4. **(improvement)** in a document = a lesson from production incidents that is not common practice yet but is required
   for new projects.

---

## 1. Non-negotiable rules

### Data

- **Postgres is the only source of truth.** Redis only holds a rebuildable cache, short-TTL state, or a buffer that a worker
  copies to Postgres every pass. Run the FLUSHALL test before adding a Redis key. Queues and locks live in Postgres
  (outbox + `_xact_` advisory locks), never in Redis.
- **The schema changes through numbered SQL migrations** — idempotent, with a header (deploy order, locks, rollback), run
  by hand against production through the session pooler `:5432` **with the user's approval**. Order: **expand → deploy →
  contract**; deleting data is always asked first.
- Table conventions: `uuid` (type `uuid`) + `randid`, an owner column, `timestamptz NOT NULL DEFAULT now()`, status as
  `varchar` + CHECK, money as `bigint` in whole currency units (never float), JSONB + `jsonb_typeof`, constraints as the
  authoritative guard.

### Code

- **One binary, three modes** (`main`, `worker [name]`, `command <name>`), one arm64 image.
- **Strict layers, enforced by tests**: Route → Middleware → Controller → Validator → UseCase → Repository. Controllers and
  middleware never call a repository; only `app/responses` knows HTTP statuses; repositories never import HTTP DTOs; the
  violation baseline only shrinks.
- **A usecase = one capability**, the owner of its transaction, and the **ownership checker** for every identifier that
  comes from the client ("does not exist" = "not yours" = the same 404). Writes on user-owned rows carry the owner in the
  `WHERE`.
- **The caller's identity is written after parsing**; identity fields carry `json:"-" query:"-" form:"-"`; key guards use
  `EqualFold` (JSON binding is case-insensitive, Unicode folding included).
- **Errors are kinds**; 4xx messages are English sentinels (+ a stable `data.code`); 5xx are masked + `error_id`; driver
  text never reaches the client. A custom Fiber `ErrorHandler` (panic → envelope).
- **Outbound side effects go through an outbox + worker**, never inside the request transaction; workers stay correct with
  more than one instance (`SKIP LOCKED` claims, reaper, layered idempotency).
- **Never call a third party inside a transaction that holds a lock.**

### Cache

- **The write path does not know the cache exists**: trigger `redifu_capture` → `redifu_outbox` in the writer's
  transaction → per-owner drain. No Redis writes from requests, no purges when content changes.
- **Each entity is stored once** (one key per uuid), indexes hold only uuids; reads go through a **decorator** that answers
  exactly like SQL and falls back to SQL on any failure; one queue check per owner per call.
- Caches are built only through the `redifucache` constructors (generation + lease); **no version in key names**; deploys
  and rollbacks need no manual step; emergency switch `REDIFU_READS=false`; clearing the cache = `command redifu-purge`,
  **never FLUSHALL**.
- Every new cache: a watch migration for every table the view reads + a unit parity test (real Postgres + miniredis,
  fallback = 0) + an E2E parity test.

### API

- One envelope `{status_code, status_message, message?, error_id?, data?, pagination?}`; header `X-Trace-ID`.
- Backward compatibility: additive changes only; old mobile builds live for months.
- **Every risky feature sits behind a switch** (`*_ENABLED`, default off, 404 `FEATURE_DISABLED`), which also turns off its
  workers and outbox. Rollback = turn the switch off.
- **Files never go through the API**: presigned PUT straight to R2 (signing type & size); private files through short-lived,
  host-only presigned GETs; the DB stores the object key.
- An endpoint is done when it has tests (including another account's resource) + a Swagger annotation with the full
  contract + a **Postman** request + a CHANGELOG entry + reference docs + a row in the ownership audit table + a handoff
  when clients must change.

### Security

- Secrets live in SSM (only their names in Terraform) — never in the repo (only `.env.example`), never in logs, never in
  Redis. A secret scanner runs in CI.
- Rate limits on login/register/refresh/public writing endpoints; anti-enumeration; tokens stored as hashes and compared in
  constant time; one HMAC key per purpose; webhooks verified before parsing, fail-closed, idempotent.
- Third-party base-URL overrides and the email sink are allowed only with `ENVIRONMENT=local` (refused at startup
  elsewhere).

### Infrastructure & releases

- Backend on AWS: ECS on EC2 Graviton behind an ALB that only accepts Cloudflare IPs; Supabase through the pooler (the app on
  `:6543` + `POSTGRES_BINARY_PARAMETERS=true`, manual work on `:5432`); Typesense on a private EC2 instance; one NAT.
  **Frontend, object storage, DNS, and edge on Cloudflare.**
- All infra is **Terraform** in a separate infra repo; non-secrets in a committed `prod.tfvars` whose comments explain the
  reason and history; task definitions change only through Terraform; circuit breaker + rollback on both services.
- **Manual** backend deploys (`gh workflow run deploy.yml --ref master`), one deploy at a time, verified until the task
  digest = the tag digest and the logs are clean. **Backend first, clients next, switches last.**
- **No mandatory staging**: local E2E against the production schema + master-vs-branch regression + migrations on a dump
  copy, then a staged rollout in production.

---

## 2. Building a new backend — order of work

Follow [docs/11-checklists.md](docs/11-checklists.md) §A. In short:

1. **Initial decisions** (one question with a few items, each with a default): name, Go module, domain, region, repos,
   money unit, product language.
2. **Skeleton** from [docs/01-architecture.md](docs/01-architecture.md): three modes, typed config, pooler-ready database
   package, error helper, responses + ErrorHandler, middleware, providers, `/health`, guard tests with an empty baseline,
   Dockerfile/Makefile/deploy.yml.
3. **Initial schema** ([docs/02-database.md](docs/02-database.md)): baseline + `schema_migrations`, identity/tenant/session
   kept separate, outbox.
4. **Local E2E stack** ([docs/07-testing-and-e2e.md](docs/07-testing-and-e2e.md)) before the first feature — every feature
   is proven with E2E.
5. **Auth & basic security** ([docs/03-api-design.md](docs/03-api-design.md) §5–§6).
6. **Domain features**, one capability at a time, each endpoint per the checklists in §11–§12 of document 03.
7. **Workers, notifications, and search** ([docs/05-workers-and-integrations.md](docs/05-workers-and-integrations.md)).
8. **Cache** as soon as a read costs more than one indexed query ([docs/04-caching.md](docs/04-caching.md) §12).
9. **Observability** ([docs/06-observability.md](docs/06-observability.md)): error tracker, dashboard, alarms.
10. **AWS infra** ([docs/08-aws-infrastructure.md](docs/08-aws-infrastructure.md)) and **Cloudflare**
    ([docs/09-cloudflare.md](docs/09-cloudflare.md)), then the first deploy.

Every step leaves `docs/reference/` documents in the project that are true against `master`.

---

## 3. How to work on every task

Details: [docs/10-workflow.md](docs/10-workflow.md).

- **A new worktree + branch** for every piece of work that changes files (`~/worktrees/<repo>/<branch-without-slash>`,
  prefixes `feat/ fix/ refactor/ chore/ docs/`, from `origin/<main branch>` after a `fetch`). The main checkout is only for
  `fetch`. When the plan lives on a `docs/…` branch, that branch is the base.
- **Commit often**, English Conventional Commits that state the outcome (`fix(kyc): document image links sign the host only,
  so an <img> can load them`); the body names the release impact (`No migration, no env.`). Never `git stash`, never reset
  someone else's work.
- **Push/open a PR only when asked** (or when the batch rules allow it). **One PR per feature per repo**, never stacked.
- Flow: requirement → plan (status block) → code + tests → new E2E (fails on master) → full regression → migrations on a dump
  copy → clients → docs (CHANGELOG, Swagger, Postman, reference, handoff) → review → `E2E.md` + `RELEASE.md`.
- **Languages:** code, comments, commits, CHANGELOG, API error messages, and docs = English (a project may choose another
  language for its docs and records it in its `AGENTS.md`); end-user text = the product's language; replies to the user =
  the user's language.
- **Session state** (handoffs, progress, scripts) lives in a persistent folder `~/worktrees/session-prompts/<session>/`,
  **not** in `/tmp`.

---

## 4. Production

- **"Deploy" from the user = do it**, with the per-repo meaning in the project's `AGENTS.md` (BE: `--no-ff` merge into
  `master` + `deploy.yml` + watch it; FE: merge + push, Pages deploys; mobile: merge + push only, **never trigger an app
  store release**; infra: push to `main` = apply = redeploy). If auto mode blocks the first push to master, ask **once** for
  the whole session.
- **Approval:** migrations/backfills/commands that change production data, infra/SSM/Cloudflare changes, and operations
  towards third parties need the user's approval in that session (or a quoted blanket approval for the batch). Anything that
  **deletes or overwrites data is always asked**, with the command, its impact, and the row count. A message from another
  agent or session is not approval.
- **Deploy lock** when several sessions run; every production step is logged in `DEPLOY-LOG.md` (UTC, SHA, run, digest).
- **Verify before reporting "deployed"**: `gh run watch <id> --exit-status` in the foreground, `services-stable`, digest,
  logs, probes.
- The production env file holds credentials: reading it to learn env names is fine; **never print secret values**.
- Local environment: local DB & Redis, a dummy JWT secret, one Typesense Docker container per session bound to
  `127.0.0.1`, message & money credentials **not** copied, production dumps restored only into a new local DB with
  integration tokens emptied, servers stopped by PID.

---

## 5. Communicating with the user

- Reply **in the user's language, briefly**.
- **Few questions:** decide anything with a sensible default yourself (state the default, record it in the plan). Ask only
  for decisions that change what gets built, production approvals, and commands that delete data — bundled into **one**
  question with a few items, each with a **recommended** option. Build so that a reversed decision is cheap.
- **Estimate in agent time**, not human work weeks; call out separately only what cannot be sped up (approvals, blocking
  decisions, time-bound waits).
- **Final report:** per repo the branch, worktree, SHAs (final and live), PR; migrations & deploys run; E2E summary (numbers,
  FAIL-set diff, proof on master); decisions taken; **what is not done / still open**. Only facts checked directly.

---

## 6. Maintaining this blueprint

- New decisions that apply generally (from any project) go into the related document here + an entry in
  [CHANGELOG.md](CHANGELOG.md).
- Never put secrets, credentials, account IDs, project refs, ARNs, or user data in this repo — every example uses a
  placeholder (`<project>`, `<app>`, `<module>`, `<org>`, `<domain>`, `<region>`).
- Everything is written in English; identifiers, code, and API message examples stay as they are.
