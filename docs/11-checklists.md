# 11 — Checklists

Short checklists. Every item points to the document that explains how and why.

---

## A. Bootstrapping a new project

### A0. Initial decisions (ask them together, with defaults)

- [ ] Project name/`<project>`, Go module `github.com/<org>/<app>`, product domain, AWS region (default: the region closest
      to the users, e.g. `ap-southeast-1`), product language for end-user text.
- [ ] Repos to create: BE, infra, web, (dashboard), (mobile), (edge). Main branch name per repo.
- [ ] Money unit (default: bigint in whole currency units), the platform's business time zone (for fixed schedules).
- [ ] Accounts: a dedicated AWS account, a Supabase project, Redis Cloud, a Cloudflare zone, GitHub org/secrets.

### A1. Backend repo & skeleton ([01-architecture.md](01-architecture.md))

- [ ] Worktree + branch ([10-workflow.md](10-workflow.md) §2). `AGENTS.md` from
      [templates/project/AGENTS.md](../templates/project/AGENTS.md); `CLAUDE.md` = `see @AGENTS.md`; copy the blueprint to
      `docs/blueprint/` (record the SHA).
- [ ] Folder structure `app/…`, `migrations/`, `backfills/` (+ README), `scripts/e2e/`,
      `docs/{requirements,plans,handoffs,reference}/`.
- [ ] `app/cmd/main.go` with three modes (`main`/`worker`/`command`), `time.Local = time.UTC`, slog JSON logger, build line;
      `app/buildinfo`; one registry for workers/commands.
- [ ] Typed `app/config` (unknown env values → warning/fail at start; JWT secret ≥ 32 bytes outside local; base-URL
      overrides only in local).
- [ ] `app/database` (DSN with quoting, TLS `require`, binary parameters + `[]byte` → text wrapper, pools from env,
      connection retry 10 × 5 s).
- [ ] `app/helper` (`ErrorLog`, `Kind`, `HTTPStatusOf`, `NewErrorLog` + `DiagCtx`, `error_id`), `app/responses`
      (`SendResponse`/`SendError`, 2xx = Success), a custom `fiber.Config.ErrorHandler` (panic → envelope).
- [ ] Middleware: trace, CORS (allow-list from config, pinned by a test), logger (with `trace_id` + the real client IP),
      recover, `FeatureFlagMiddleware`, auth (bearer → session → user), `AdminOnly`.
- [ ] Providers (`RepositoryProvider`, `UseCaseProvider`), `GET /health` (503 only when the pool is exhausted).
- [ ] Guard tests from day one: `TestArchitecture` (empty baseline), `TestErrorLogCalls`, route access test, CORS test.
- [ ] `Dockerfile`, `.dockerignore`, `Makefile`, `.github/workflows/deploy.yml` from [templates/backend/](../templates/backend/).
- [ ] `.gitignore` covers every `.env*` except `.env.example`; gitleaks in CI.

### A2. Database ([02-database.md](02-database.md))

- [ ] `000_baseline.sql` + `schema_migrations`; a `gen_randid()` function.
- [ ] Initial tables follow the conventions (uuid + randid, owner, `timestamptz NOT NULL DEFAULT now()`, varchar enum + CHECK,
      bigint money, JSONB + `jsonb_typeof`).
- [ ] Identity/tenant/session/membership tables separated from the start ([03-api-design.md](03-api-design.md) §5.1).
- [ ] Notification outbox + signal queue ([templates/backend/sql/notification_outbox.sql](../templates/backend/sql/notification_outbox.sql)).
- [ ] CI: replay every migration on an empty Postgres twice.

### A3. Local E2E stack ([07-testing-and-e2e.md](07-testing-and-e2e.md))

- [ ] `scripts/e2e/local/{env,db-reset,up,down}.sh` from the template; schema snapshot (at first: from the migrations; once
      production has data: from a production dump) + `seed.sql`.
- [ ] `scripts/e2e/{client.go,main_test.go}` + shared account helpers + `waitForEmail` (file sink).
- [ ] A fake for every third-party integration in use.

### A4. Auth & basic security ([03-api-design.md](03-api-design.md) §5–§6)

- [ ] Login/register/refresh (rotation)/logout/reset/email verification; one login message + throttling; anti-enumeration.
- [ ] JWT with `typ`/a derived key per token type, a parser with `WithValidMethods`/`WithExpirationRequired`/`WithIssuer`.
- [ ] argon2 passwords + policy + test vectors shared with the clients.
- [ ] Per-IP and per-identity rate limits; the ownership audit table is started.

### A5. Workers, notifications, search ([05-workers-and-integrations.md](05-workers-and-integrations.md))

- [ ] `runWithSignal` + `safeTick` + WaitGroup; `worker --check` in CI.
- [ ] Notification catalog in code, embedded templates + fixtures, boot gate, kill switch per channel, local email sink.
- [ ] Typesense: schema in code, `Ensure*Collection`, indexer fed by a signal outbox, owner-scoped SQL hydration.

### A6. Cache ([04-caching.md](04-caching.md) §12)

- [ ] Copy `app/redifucache` (+ its tests), remove `legacyFormats`; the `redifu_outbox` migration from the template.
- [ ] First cache (the most-read owner list) + unit parity + E2E parity.

### A7. Observability ([06-observability.md](06-observability.md))

- [ ] Error tracker (worker + DynamoDB table + admin endpoints + dashboard page), metrics wrapper, CloudWatch dashboard &
      alarms, Logs Insights queries in a runbook.

### A8. AWS infrastructure ([08-aws-infrastructure.md](08-aws-infrastructure.md))

- [ ] A dedicated AWS account + a named CLI profile.
- [ ] Outside values: Cloudflare token (DNS Edit, one zone), zone ID, Origin Certificate → ACM, SSL Full (strict),
      Typesense API key.
- [ ] Repo `<project>-prod-infra`: `bootstrap/` (state bucket, lock table, OIDC + terraform & deploy roles) → apply from a
      laptop.
- [ ] `terraform/prod.tfvars` from [templates/infra/prod.tfvars.example](../templates/infra/prod.tfvars.example);
      `terraform.tfvars` (local secrets); first apply from a laptop.
- [ ] First `linux/arm64` image into ECR; the services come up.
- [ ] GitHub Secrets (infra: `AWS_TERRAFORM_ROLE_ARN`, `CLOUDFLARE_API_TOKEN`, `TF_VAR_*`; BE: `AWS_DEPLOY_ROLE_ARN`,
      `GOPRIVATE_TOKEN`); `terraform.yml` from the template.
- [ ] SSM filled (`put-secrets.sh`); SES production access requested; circuit breaker on both services.

### A9. Cloudflare ([09-cloudflare.md](09-cloudflare.md))

- [ ] Pages for the web app (`<project>-fe-main`, optional `-staging`) + the internal dashboard, Git integration.
- [ ] R2: a public bucket + custom domain `cdn.<domain>`, a private bucket, bucket CORS, R2 access key in SSM.
- [ ] Edge Worker (when bots need SEO/OG or there are alias domains) with `[env.staging]`/`[env.main]`.
- [ ] Backend CORS covers every origin; reserved usernames in sync between backend and web.

---

## B. A new feature (across repos)

- [ ] Brief in `docs/requirements/` (sender's file name); plan `docs/plans/<x>.md` (status block, K#, P#, tests, release,
      "Done means") — template [templates/docs/plan.md](../templates/docs/plan.md).
- [ ] Worktree + branch per repo; base = the plan's branch when the plan lives on a docs branch.
- [ ] Migration (C), model, repository (+ cache when needed, D), DTOs, a usecase per capability (ownership!), validator,
      controller (Swagger with the full contract), route (feature switch, default off).
- [ ] Every new model embeds `*redifu.Record` and has its initiator `New<Entity>()` (calls `redifu.InitRecord`); new
      instances are created only through it, never as inline struct literals; everything the cache stores embeds
      `*redifu.Record` ([01-architecture.md](01-architecture.md) §6.1).
- [ ] Tests: usecase (another account is refused), validator (every spelling of identity keys), route, E2E per case (fails
      on master).
- [ ] Full regression master vs branch; migrations on a dump copy.
- [ ] Postman, `make gen-swagger`, CHANGELOG, `docs/reference`, ownership audit table, handoff
      ([templates/docs/handoff-frontend-prompt.md](../templates/docs/handoff-frontend-prompt.md)).
- [ ] Clients: unit/lint/build, Playwright/Flutter against the local BE, screenshots.
- [ ] Review → fixes → `E2E.md` + `RELEASE.md`.
- [ ] READY TO MERGE ([10-workflow.md](10-workflow.md) §1.1).

## C. Migration

[02-database.md](02-database.md) §4.12 (writing → before production → running).

## D. Cache for a new view

[04-caching.md](04-caching.md) §11 (12 steps: decide → watch → SQL tiebreak → entity + Shape → handler → decorator →
provider → unit parity → E2E parity → guard tests → docs → release).

## E. New endpoint

[03-api-design.md](03-api-design.md) §11 (security checklist) and §12 (definition of done).

## F. A new worker / outbox

- [ ] Outbox variant chosen (snapshot / signal / job); rows written in the business transaction; the producer refuses
      `tx == nil`.
- [ ] `SKIP LOCKED` claim + `locked_at` + reaper; retry/backoff + `FAILED`; idempotency; retention.
- [ ] Loop: a timeout per I/O call, no logs when idle, `safeTick`, one failing item does not drop the batch.
- [ ] The feature switch turns off the worker & outbox; the worker is listed in the registry + `Makefile` + help.
- [ ] Backfill enqueue (after the worker is live); E2E tests with `E2E_EXTRA_WORKERS`.

## G. A new third-party integration

- [ ] Client (wire format) and sender/usecase (decisions) kept apart; timeouts; error classification; credentials checked at
      construction.
- [ ] Secrets in SSM (filled before their reference reaches `main`); base-URL overrides only in local.
- [ ] Webhooks: HMAC over the raw body, constant-time, anti-replay, fail-closed, idempotent, masked body logging.
- [ ] A fake for E2E (+ control plane), a webhook sink for first observations.
- [ ] A kill switch when it is paid/risky; a setup runbook.

## H. Release

- [ ] Deploy lock taken; base re-checked; the release contains only what was tested ([10-workflow.md](10-workflow.md) §6.5).
- [ ] Pre-deploy migrations (approval) → `--no-ff` merge (message summarizes the impact) → `deploy.yml` →
      `gh run watch --exit-status` → `services-stable` → digest = tag → clean logs → probes
      ([08-aws-infrastructure.md](08-aws-infrastructure.md) §6).
- [ ] Post-deploy migrations → web/dashboard (Pages check + live bundle) → mobile push only (no workflow) → feature switches
      (infra apply) → post-release work.
- [ ] DEPLOY-LOG, `DEPLOYED` marker, lock released, final report.

## I. Closing a session

- [ ] Everything committed; branches & worktrees reported; session folder holds PROGRESS/E2E/RELEASE/DONE.
- [ ] Containers/stand-ins/servers stopped; unused local DBs dropped; temporary comparison worktrees removed.
- [ ] Final report: SHAs per repo, PRs, migrations, deploys, E2E, decisions, **what is not done / still open**.
- [ ] A short memory note (new lessons).
