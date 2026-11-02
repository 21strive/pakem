# 10 — Workflow: git, documents, releases, production, agent sessions

How agents and humans work: from the brief to a feature live in production, plus the rules for the local
environment, production approvals, and orchestrating many agent sessions. Testing is detailed in
[07-testing-and-e2e.md](07-testing-and-e2e.md); the deploy infrastructure in [08-aws-infrastructure.md](08-aws-infrastructure.md)
and [09-cloudflare.md](09-cloudflare.md).

Markers: **MUST** (hard rule; has caused real problems or was requested by the user), **MUST NOT**, **SHOULD**
(default; deviating is allowed with a written reason). Section §10 contains **recommended improvements** for new projects
that are not yet common practice — clearly marked.

---

## 1. Flow map for one feature

1. **Requirement arrives** (web/mobile/product brief) → copied into `docs/requirements/` under the sender's file name.
2. **Backend plan** written in `docs/plans/<x>.md` (status block, decisions K#, work packages P#, tests, release, "Done
   means"). The plan often lives first on a `docs/<x>` branch.
3. **Worktree + work branch.** If the plan is on a docs branch, the work branch is created from that docs branch.
4. **Implementation + unit tests + guard tests** (architecture, error messages, route access). Commit often.
5. **New E2E** in `scripts/e2e` for **every** test case in the plan; new tests **must fail** on the master binary.
6. **Full-suite regression**: master binary vs branch binary, compare the `--- FAIL` sets.
7. **Migration test** on a clean DB and on a production dump copy.
8. **Client test** (web, dashboard, mobile) against the local BE + visual evidence (screenshots).
9. **Documents**: CHANGELOG, Swagger (generated), Postman (manual), reference & runbooks, client handoff, plan status,
   the `docs/README.md` index.
10. **Review** (`/code-review` or a reviewer sub-agent), fix the findings, rerun the affected tests.
11. **Evidence** in `E2E.md` and the release steps in `RELEASE.md` (session folder).
12. **Release path:**
    - Without a deploy request: **one PR per repo** (if the user asks for a PR); the user merges.
    - With a deploy request: merge directly under the **deploy lock**, in this order: pre-deploy migrations → BE +
      verification → post-deploy migrations → web/dashboard → mobile (push only) → feature switch.
13. **Close**: `DEPLOY-LOG.md`, `DONE`/`DEPLOYED` markers, final report to the user, memory note.

### 1.1 Definition of "READY TO MERGE"

All of the following must hold:

- `go build ./...` and `go vet` on the changed packages pass.
- The `go test ./...` FAIL-set **equals** master's FAIL-set (as a set, not the exit code).
- Guard tests green: `TestArchitecture`, `TestErrorLogCalls`, the route access tests, and the feature's new guard tests.
- New E2E for every test case in the plan (including negative & boundary cases): **FAIL (not SKIP) on master, PASS on
  the branch**.
- Full-suite regression, master vs the final branch: no FAIL that appears only on the branch (or it is explained/fixed).
- Migrations tested on a clean DB and on a production dump copy: run time, idempotency, row counts.
- Clients: unit tests & lint/analyze no worse than the baseline of their main branch; browser e2e when the plan asks for
  it; UI changes have screenshots.
- Swagger, Postman, CHANGELOG, reference, handoff, plan status updated.
- Review done and its findings fixed.
- `E2E.md` and `RELEASE.md` written.

---

## 2. Git

### 2.1 MUST: a new worktree + branch for every piece of work that changes files

- Path: `~/worktrees/<repo>/<branch-without-slash>`. Branch name: `feat/`, `fix/`, `refactor/`, `chore/`, `docs/` + a
  lowercase description separated by hyphens.
- Base: `origin/<main branch>` after `git fetch origin` (BE `master`, web `main`, mobile `develop`, dashboard
  `master`, infra `main`).
  ```bash
  git -C ~/<repo> fetch origin
  git -C ~/<repo> worktree add -b feat/<x> ~/worktrees/<repo>/feat-<x> origin/master
  ```
- **The main checkout is only for `fetch`.** MUST NOT edit there, MUST NOT commit directly to the main branch (the main
  branch = production; the main checkout is used by many parallel sessions).
- Extra worktrees (comparison builds, sub-agents) also go in `~/worktrees/<repo>/<name>`, on the same disk (not
  `/tmp` — it is tmpfs: `cp -al` fails across devices, and it is wiped on reboot).
- **Base from the plan's branch:** when the user says "kerjakan plan dari branch docs/…" ("implement the plan from the
  docs/… branch"), the base is that docs branch, not `origin/master` — even if the plan says master. Merge
  `origin/master` later if master moves.
- End of the work: report the branch name + worktree path. Remove the worktree only when asked or after it is merged.
- Exceptions: read-only work; the user asks for an existing branch (push fast-forward to it); continuing a task in the
  same session.

### 2.2 MUST: commit often, never throw work away

- Commit every unit that builds & passes its tests, at least once per work package, and **before** long test runs.
  Forced to stop midway: `wip(<area>): …`.
- MUST NOT use `git stash` (it is shared by every worktree of that repo) — use a WIP commit.
- MUST NOT run `git reset --hard`, `git clean`, `git checkout -- .` on work that is not yours. Uncommitted changes in a
  worktree inherited from a predecessor: read the diff, finish it, test, commit.
- Reason: a session can be cut off (limits, VM shut down, OOM); a commit is the only state that is sure to survive.

### 2.3 MUST: commit message format

- Conventional Commits `type(scope): subject`, in English. Types: `feat`, `fix`, `docs`, `test`, `refactor`,
  `chore`, `perf`, `style`, `wip`. Scope = domain/area (`notifications`, `kyc`, `cors`, `e2e`, `plans`, `deps`, `db`,
  `redifu`). In clients a UI area name is fine.
- The subject states the **visible result/behavior**, not its mechanism; lowercase after the colon; no trailing period.
  ```
  fix(kyc): document image links sign the host only, so an <img> can load them
  chore(deps): <library> v0.10.0
  test(e2e): account deletion hands the owner their next account
  docs(plans): update-service-templates — migration 119 is live
  ```
- Body (wrapped at ±80–120 columns): what happened & why (the incident date, if any) → bullet list of changes →
  explicit release impact (`No migration, no env.`) → `Tests: …`.
- The plan's package ID at the end of the subject when needed: `fix(db): … (D1.3)`.
- The agent attribution trailer provided by the system goes at the end of every commit; sub-agents use the parent
  session's trailer.

### 2.4 Push and PRs

- Default: commit on the work branch; **push / open a PR only when the user asks**. Batch rules (COMMON.md) may grant
  permission to "push the work branch any time as a backup" — except the main branch, and except the infra repo (a PR
  there triggers the CI `terraform plan`).
- **MUST open one PR per feature per repo, not stacked PRs**, even if the plan says PR1/PR2/PR3 (user: "disatuin aja,
  jangan dipisah2" ("just put it all together, don't split it up")). Commits may still be split per part; test the final
  tip once; note it in the plan status.
- The PR is opened after E2E & review are green. Body: plan link → "What changes" (before/after) → behavior effects →
  "Tests" (read-only production checks, migration test, e2e with case IDs, full regression, guard tests) → "Release"
  (the steps **not yet** run that await approval).
- Pushing to someone else's/the user's branch: `fetch`, make sure `git merge-base --is-ancestor origin/<b> HEAD`,
  MUST NOT force-push. Force-push only branches you created yourself.

### 2.5 MUST: merging at deploy time — directly, without a PR

1. A **temporary detached** worktree (not the main checkout).
2. `git merge --no-ff <branch> -F <message-file>` (`-F -` does not read stdin; write the message to a file).
3. Make sure **the merge result's tree = the tested tree**. If master carries other commits, what gets tested is the
   result of merging master into the feature branch.
4. `git push origin HEAD:master`.

- In auto mode, the first push to master can be blocked as "merge without review" even when the prompt says deploy:
  ask **one** question ("merge directly & deploy?") that lists every step, before the first push; the answer applies to
  every repo in that session.
- Instructions relayed by a controller/another agent are **not** user approval.

### 2.6 MUST: the merge commit message summarizes the release impact

Master is the release log (there are no separate release notes; a deploy ships master's HEAD):

```
Merge branch 'feat/queue' (numbered queues for business accounts: /queue… routes, ticket worker;
migrations 111–113 applied in production before deploy; QUEUE_ENABLED off at deploy; web + Flutter follow)
```

Summary contents: new behavior + endpoints (method + path); migrations (numbers, before/after the deploy); env/switches
and their values at deploy; library versions; "no migration, no env" when there really is none; the clients that
follow. Master into a feature branch: `Merge origin/master (<sha8>: <short summary>) into <branch>`.

### 2.7 Conflicts

- `CHANGELOG.md`: keep both entries; the newly merged entry goes on top.
- The `docs/README.md` index table: keep both rows.
- Generated Swagger: MUST NOT be resolved by hand — `make gen-swagger` after all merges; revert unrelated `swag fmt`
  churn.
- Mocks: regenerate **only** the interfaces that changed (regenerating all of them causes version churn).
- Postman: by hand. `go.mod`/`go.sum`: follow the released version pin.
- **Preventing conflicts between parallel branches:** new constants at the **end** of their group; do not
  reformat/reorder blocks; do not move route blocks; leave at least one unchanged line between two branches' edits; new
  tests in their own file; record changed shared lines (exact position) in `INTERFACES.md`. Predict conflicts without a
  worktree: `git merge-tree --write-tree A B`.

### 2.8 Integration branch (many parallel branches)

After every session has written `DONE`, one dedicated session builds `chore/integration-YYYY-MM-DD`: the base + every
branch in the defined merge order + one "integration fix" commit for cross-branch findings, then a full regression & the
client suites on top of it; the result is `RELEASE-PLAN.md`. Releasing is recommended as **a single fast-forward of the
integration branch to master** (its tree is exactly what was tested). If the base moves midway: re-fetch right before the
push; rebuild; check `git diff old new` == the base delta; rerun the suites.

### 2.9 Internal libraries (separate Go repos)

Release = fast-forward the main branch + annotated tag `vX.Y.Z`, then in the BE `go get <module>@vX.Y.Z`. Develop with a
local `replace`, **do not commit** the `replace`. A branch pseudo-version only by user decision.

---

## 3. CHANGELOG

- **MUST:** every behavior change (API, DB, logs, ops, test tooling) has an entry, written on the feature branch, in
  English, together with its code. Newest entry on top, one entry per feature/fix.
- Entry format:

```md
## [Unreleased]

### <Title stated as an outcome, e.g. "Payment webhooks: the body reaches the log">

<Opening paragraph: plan/reference/runbook links; background (incident + date); release impact in bold, one of:
 **No migration**, no environment variable.
 **Requires migration `097_drop_offline_method_columns.sql`** (destructive, approved by the user on <date>; …)
 Ships with internal-dashboard `feat/…` (clients that must follow).
 **Applied to production 2026-10-27 22:21:54 UTC.**>

- `[API]` <behavior per endpoint: request/response, status + message, limits, compatibility with old clients>
- `[DEV]` <new e2e tests (TestX + case IDs), harness, seed, fakes>
```

- MUST be mentioned: migrations (file name, destructive or not, when relative to the deploy, special handling such as
  "run by hand, CONCURRENTLY"); new env/switches + their defaults; rollback bans ("do not roll back past …"); clients
  that must follow.
- Uppercase area tags from a fixed list (see §10): `[API] [DB] [CACHE] [WORKER] [NOTIFICATION] [SEARCH]
  [SECURITY] [ADMIN] [LOG] [OPS] [DEV]` + the project's domain tags.

---

## 4. Documents

### 4.1 Four `docs/` folders, distinguished by who writes for whom

| Folder | Written by → for | Contents | Lifetime |
|---|---|---|---|
| `requirements/` | web/mobile/product team → backend | briefs, PRDs, decisions; one flat folder; the sender's file names are kept | a copy; the living version is in the sender's repo |
| `plans/` | backend/agent → backend | agent prompts (`*-backend-prompt.md`), work orders, implementation/migration plans, audits | done → archive of decisions |
| `handoffs/` | backend → frontend & mobile teams/agents | self-contained prompts to be copied whole once the endpoints are live (`*-frontend-prompt.md`) | single use per release |
| `reference/` (+ `runbooks/`) | backend → all engineers | how the system works **today**; runbook = operational procedure | living; changes together with the code |

Flow: requirement → plan → code → handoff → `reference/` updated. A plan/handoff names the requirement it fulfills
(`Fulfills: docs/requirements/BACKEND_X.md`). A plan that has been released is **not moved**; write/update the reference.
`docs/README.md` is the index of every document (a latest-status column for plans; the copy's origin for requirements).
Templates: [templates/docs/](../templates/docs/).

### 4.2 Requirements

Top block: `> **For:** backend team · **From:** web team · <date>, **revised <date>**` and
`> **Checked against:** <repo> origin/master <sha> (<date>, last migration NNN)` (+ the relevant production
state). Code, tests, and migrations cite the brief by name + section number (`BACKEND_VOUCHER.md §7.2`), so file names
are not changed. User artifacts (claude.ai pages) are exported to text and imported as requirements before the plan is
written.

### 4.3 Plans

- **Status block at the top**, updated at every milestone/PR/release; readers **must** check the status block first
  before assuming the plan's contents describe the running code.
- Standard sections: Summary → What changes / per endpoint → **Decisions** (`# | Decision | Reason`, K1…) →
  **Work packages** (P1…Pn, including "Release to production") → Tests/E2E per package → Order of work & release → Risks
  → Outside this plan → **Done means** → **Implementation status** (`Package | Status | Commit` + "What was proven" +
  "Release").
- Decisions made during implementation are recorded in the status block and the Decisions section. Plan steps that
  cannot be carried out are replaced and the reason is recorded (e.g. "staging" → local validation + staged rollout;
  stacked PRs → one PR).

### 4.4 Handoffs (backend → clients)

Self-contained, handed over **after the endpoints are live**, **written even when the client is built by the same
agent** (contract + archive). Top block: base URL, auth, "verified against commit `<sha>` on master, migration NNN",
Postman folder, Swagger link, plan link. First section: "The mental model — read this first", then the traps that are
easiest to get wrong, then per endpoint (request, response, errors + messages, examples), then the expected UI changes.

### 4.5 Reference & runbooks

`reference/` = today's truth, **updated on the same branch as its code**. Runbook:

```md
# <title>
**Written:** <date> · plan [`<x>.md`](…) §n
> ### Why the order must not be reversed   (table of old/new code × old/new data combinations when the order is critical)
## Rules for running one
## <instance>
### Before (read-only)   → check queries + EXPLAIN
### Run                  → exact command + the correct output
### Verify
### If it failed
### Rollback
```

### 4.6 API specification

Swagger is generated from controller annotations (`make gen-swagger`). **Postman must be updated by hand**: a feature is
not done until every new endpoint has a Postman request with example body & params (including special headers).

### 4.7 Language

| What | Language |
|---|---|
| code, comments, commits, CHANGELOG, API error messages, PR bodies | English |
| plans, handoffs, requirements, `reference/` & runbooks, session files (COMMON/HANDOFF/PROGRESS/E2E/RELEASE) | English by default — a project may pick **one** other language for its docs and records it in its `AGENTS.md`; identifiers stay in English |
| end-user text (UI, email, WhatsApp) | the product language, following the surrounding code |
| replies to the user | the user's language, concise |

### 4.8 Backfills

One-off DML in `backfills/<what>.sql`: no number, **idempotent** (`NOT EXISTS`/`ON CONFLICT DO NOTHING`), a header
(what it fills, the related migration, the reason, the worker that drains its queue), verification queries as comments
at the bottom, no DDL (except `pg_temp` helpers), run by hand after the related migration. Data that is *part of* a
schema change stays in its migration. Details: [02-database.md](02-database.md).

---

## 5. Cross-repo & staged releases

1. **Order (MUST):** pre-deploy migrations → BE until the rollout is `COMPLETED` → web & dashboard → mobile (push only) →
   feature switch turned on → post-release (cache purge if needed, switch `log` → `enforce`, old endpoints removed
   after N days). Clients must not call endpoints that do not exist yet.
2. **Backward compatibility (MUST):** add fields, do not change the meaning of old fields (example: `google_status`
   was added, `google: true` stays for old apps). Check which mobile builds are still in circulation before installing a
   new gate. Outbox/notification rows that are already queued must still be renderable by the new template.
3. **Feature switches:** `FeatureFlagMiddleware` in front of the routes; the BE deploys with the switch **off** →
   clients release → the switch is turned on through the infra env (API **and** worker). Local regression uses the
   production switch values.
4. **`off|log|enforce` mode** for new validations/gates: set `log` in the env **before** the code deploy, watch the
   rejection metrics (e.g. ±7 days), then `enforce`. A real trap: switches that treat an empty value as
   `enforce` — deploying without setting the env first shut the feature immediately (every `/admin/*` 503). See §10.
5. **Expand/contract (MUST) for destructive changes:** release code that stops using the column (drop NOT
   NULL/CHECK, stop writing & reading) → DROP later with user approval → record the rollback ban in the CHANGELOG.
6. **Every migration has a run time relative to the deploy (MUST):** before the deploy (additive, old code tolerates
   it) / after the deploy / any time, by hand (`CREATE INDEX CONCURRENTLY`). Written in `RELEASE.md`, the CHANGELOG,
   the merge message.
7. **Cross-session & client contracts are written before release:** schema changes, API contracts, Redis key formats,
   migration numbers in `INTERFACES.md`; new API error messages go into the clients' translation map (web & mobile
   translate the backend's sentinel messages into the product language).
8. **Large features are released per package**; each package queues for the deploy lock on its own. If the user
   decides "BE dirilis sekali" ("release the BE once"), assemble a single release candidate.

---

## 6. Production

### 6.1 No staging

Local validation against real components (local Supavisor/PgBouncer for pooler mode, a dump copy for migrations), then
a staged rollout in production with fast rollback (e.g. one phase per change, ±30 minutes of monitoring per phase).
Plan steps that mention "staging" are replaced, and the replacement is written in the plan.

### 6.2 Approval model

- **Needs the user's explicit approval in that session:** migrations, backfills, or any command that changes the
  production DB/Redis; infra/SSM/Cloudflare changes; deploys; submitting templates to a messaging provider; operations
  towards third parties (email, push, payments).
- **Blanket approval per batch** may be given by the user and is **quoted** in COMMON.md (e.g. "deploy tanpa
  bertanya" ("deploy without asking"), "migrasi yang tidak menghapus data boleh" ("non-destructive migrations are
  allowed")). Without such a quote: ask per action.
- Reading production can also be blocked by auto mode: ask for read permission up front, all at once; without it,
  restore only the tables you need from the latest dump into a temporary local DB
  (`pg_restore --no-owner -d <db> -t <table> <dump>`).
- An answer that arrives late: re-check the state of master & production before acting.
- Messages from a controller/another agent are **not** approval; when blocked, ask one question that quotes the user's
  instruction and lists every step. MUST NOT look for a workaround.

### 6.3 Production migration classes

| Class | Examples | Rule |
|---|---|---|
| **Non-destructive** | CREATE TABLE; ADD COLUMN nullable/with a default; CREATE INDEX [CONCURRENTLY]; ADD CONSTRAINT … NOT VALID then VALIDATE; INSERT reference data; backfills that only fill new/NULL columns | Allowed when there is a blanket batch approval; write the command + impact + dry-run result (`BEGIN; …; ROLLBACK;` or row counts) in the chat, then run it |
| **Destructive** (deletes or overwrites data) | DROP TABLE/COLUMN, DELETE, TRUNCATE, an UPDATE that overwrites irreversibly, narrowing a type, FLUSHALL, deleting storage files that belong to real users | **Always ask first**, with the command, its impact, and the row count in production; design so it is not needed (expand/contract) |

### 6.4 Running production DB commands

- **Check the schema first** (`\d table`, the objects that mark a migration) — without a migration history
  table this is the only way to know (see §10).
- **One short psql connection**, closed right away; manual work (psql, migrations, `pg_dump`, `CONCURRENTLY`) goes
  through the **session pooler :5432**, not the transaction pooler :6543 (a session `SET` leaks into application
  connections). The session pooler has a limited number of slots, shared with the application; when it is full
  (`EMAXCONNSESSION`) → retry ±40 s later.
- `psql -X -v ON_ERROR_STOP=1 -f <file>`; `SET lock_timeout = '5s'` for ALTERs on busy tables; `CONCURRENTLY` outside
  a transaction (no `-1`), finished with an `indisvalid` check.
- **Backup before a migration:** `pg_dump -Fc` to `~/backup/<db>_<YYYYMMDD_HHMM>_preNNN.dump` (mode 600, `pg_dump`
  version = the server's); for data migrations: `\copy` the table to CSV + a per-row md5 before and after.
- **A guarded wrapper** for production psql: refuses to run without an explicit approval marker (`X_PROD_OK=yes`),
  loads the credentials without printing them.
- **The expected output is written down first** in `RELEASE.md` (`BEGIN`, `SET`, 15 × `UPDATE 1`, `COMMIT`); different
  output = stop.
- Migration numbers: use the session's own range; gaps in the numbering are fine; check that no branch already uses the
  number.

### 6.5 Shared deploy lock + `DEPLOY-LOG.md`

Every step that touches production — migrations, merges into the main branch, deploy workflows, infra — is done only
**while holding the `deploy` lock** (this applies to ad-hoc sessions too: a "bugfix" session once deployed on top of
another session's deploy that had finished just 40 seconds earlier).

```bash
L=<batch-folder>/bin/lock            # lock = atomic mkdir + holder file; acquire|wait|release|status
$L deploy acquire <slug> "<feature/package>"   # exit 1 = BUSY → `wait` in the background, do something else
…
$L deploy release <slug> "<result summary>"
```

Order per release:

1. **Outside the lock:** fetch every repo, merge the latest main branch into the feature branch, resolve conflicts,
   rerun E2E, record the tested SHA.
2. **Take the lock**; read the tail of DEPLOY-LOG.
3. **Re-check the base:** if the main branch has moved from the tested SHA, release the lock, repeat step 1, queue
   again. Make sure `git log <headSha of the last successful deploy>..origin/master` contains only this release's
   commits.
4. **Release** (BE → clients → switches).
5. **Log** every step, **release the lock**.

MUST NOT hold the lock during a long regression. MUST NOT delete another session's lock (a stale lock is cleaned up
after its holder has been checked). Log format (append-only, UTC):

```md
- 2026-10-16T02:24:43Z `deploy` ACQUIRED by **<slug>**: BE master + deploy.yml (no migration) → web main → mobile develop
- …T02:25:51Z [<slug>] BE master <a>..<b> `Merge branch 'feat/x'` (tree = tested branch <sha>; no migration)
- …T02:34:34Z [<slug>] deploy.yml run <id> success; api + worker COMPLETED, running digest = ECR tag <sha7>; logs clean; probe <route> → <status>
- …T02:37:20Z [<slug>] web: "Cloudflare Pages: <project>" success on <sha>; live bundle carries <chunk>
- …T02:38:17Z `deploy` RELEASED by **<slug>**: <SHA per repo, run, digest, migrations>
```

### 6.6 Deploy & verification

- BE: [08-aws-infrastructure.md](08-aws-infrastructure.md) §6 (compare the last deployed SHA vs master; `gh run watch
  --exit-status` in the foreground; `services-stable`; task digest = tag digest; 10–15 minutes of logs compared against
  the list of known noise; `/health`; probe new routes without a token; smoke tests only on your own test accounts).
- Failed rollout: ECS rolls back by itself (circuit breaker); investigate, fix forward under the same lock. Scaling a
  service or changing the DB pool = ask the user. MUST NOT roll back past a release that carried a destructive
  migration.
- Web/dashboard/edge: [09-cloudflare.md](09-cloudflare.md) §2–§3.
- **Mobile: NEVER trigger an app store release.** A mobile deploy ends with the push to its main branch; do not run any
  workflow in the mobile repo (`gh workflow run`, `gh run rerun`, API, web) and do not run `fastlane`. Before pushing,
  make sure no workflow is triggered by that push (if one is: do not push, ask the user); after the push, `gh run list`
  is unchanged.
- Infra: apply = redeploy → inside the lock, logged; fill SSM before pushing; the local plan contains only your changes.
- One-off commands in production: a one-off task with the same image, `--dry-run` first. **MUST NOT run `FLUSHALL`**;
  use `command redifu-purge` ([04-caching.md](04-caching.md)).

### 6.7 Release documents (session folder, not the repo)

- **`RELEASE.md` per session:** a status block (EXECUTED when & under which approval / NOT YET); branch/PR, contents,
  impact; numbered steps with the **exact command + the correct output + failure handling**: merge → read-only
  pre-check → backup → migration → checker → client check → rollback.
- **`RELEASE-PLAN.md`** for many branches: A. preparation (no behavior change) → B. BE in one deploy → C. web &
  dashboard → D. mobile → E. post-release; each part with post-deploy checks per feature.
- **The `DEPLOYED` marker**: one line (UTC time + user approval), SHAs, migrations, backups, check results, rollback
  pointer.

---

## 7. Local environment

### 7.1 Per-session resources

When several sessions share one machine, allocate up front and use only your own: BE port, Redis port, Typesense
container + port, gateway stand-in port, local DB prefix, **migration number range**, sub-agent ports, Vite/static
ports. Also list the ports that must not be touched. Check `ss -ltn` before using a port.

### 7.2 Local env rules per service

| Service | Rule |
|---|---|
| Postgres & Redis | always local (`redis-server --port <p> --bind 127.0.0.1 --save '' --daemonize yes`) |
| `JWT_API_SECRET` | dummy, not the production value |
| Typesense | one Docker container per session, dummy API key, **bind `127.0.0.1`** (a Docker port on `0.0.0.0` is open to the outside) |
| R2, Google, Zoom | production credentials only for entities/accounts created by tests; fakes are better (`fakes3`, `fakegoogle`, `fakezoom`) |
| Payment gateway, WhatsApp, email (SES), push | **do not copy** into the local env; use stand-ins and file sinks |
| Production dump copy | contains PII & tokens: empty the integration/device/session tokens before starting the server; do not start message/payment-sending workers; do not modify/delete real entities that have files in production storage; do not commit/share |
| Production env file | may be read to learn env names; **never print secrets** |

```bash
docker run -d --name typesense-<slug> --restart unless-stopped \
  -p 127.0.0.1:<port>:8108 -v typesense-<slug>:/data \
  typesense/typesense:<version> --data-dir /data --api-key=<dummy> --enable-cors
```

### 7.3 `.env` traps

- An empty `POSTGRES_*_PASSWORD` breaks the DSN (libpq swallows the next keyword); use a dummy password with peer auth.
- `godotenv` does not override variables that already exist, including empty ones; to override them for a second
  instance: `env PORT=… KEY= ./<app> main`.

### 7.4 Process hygiene

- Fiber listens on `0.0.0.0`: run the server only for the duration of the tests, with synthetic data.
- Stop processes by **the PID from your own pid file**. MUST NOT use `pkill -f`/pattern kills (the pattern also matches
  the calling shell; a peer once lost its regression run that way).
- Do not edit a harness script that a run is reading (bash reads it incrementally) — run a frozen copy.
- Waiters compare `date +%s`, not `date +%H%M` (a leading zero = invalid octal).

### 7.5 Locks & semaphores for shared resources

- The local CORS origin (`localhost:5173`) has one user at a time: `lock vite5173 acquire … → Vite + Playwright → stop
  Vite → release`, at most ±30 minutes; the script stops if it does not get the lock. MUST NOT commit CORS changes made
  for e2e.
- Full-regression slots and heavy client-work slots are limited (e.g. 3–4 and 2 per machine); process parallelism
  `go test -p 2`, `flutter test --concurrency=2`, `vitest --maxWorkers=2`.
- Shared local Postgres: cap each stack's pool (`POSTGRES_WRITE_MAX_OPEN_CONNS=8`, `READ=6`); check
  `SELECT count(*) FROM pg_stat_activity` before starting a stack.
- The non-production semaphore log is **separate** from DEPLOY-LOG.

### 7.6 Disk, toolchains, cleanup

- Check `df -h /` before a long regression or a release. `~/.cache/go-build` can grow to tens of GB: trim it with
  `find ~/.cache/go-build -type f -mmin +240 -delete` (`+20` in an emergency), then recreate the 256 shard directories.
- `node_modules` in a new worktree: hardlink (`cp -al`) from a worktree with the same lockfile.
- Local toolchain versions = CI (Go, Node, Flutter `.fvmrc`, Terraform `TF_VERSION`); local Postgres version =
  production. Do not install toolchains into `/tmp`.
- End of session: stop (do not delete) the Typesense container; stop stand-ins/fakes/servers; drop unused local DBs;
  remove comparison worktrees; record what was kept/deleted.

---

## 8. Agent sessions & orchestration

### 8.1 State in a persistent folder

Handoffs, progress, agent prompts, and scripts that will be needed again go in `~/worktrees/session-prompts/<session>/`
(or get committed) — **not** `/tmp`/scratchpad (wiped on reboot). Create that folder at the **start** of a long session.

### 8.2 Contents of the batch folder

| File | Contents | Writer |
|---|---|---|
| `COMMON.md` | shared rules: the user's instructions **quoted** + their interpretation; "Read first"; worktrees; resource table; definition of E2E/done; migration classes; deploy lock procedure; merge order + touch points; limits; state & reporting | controller |
| `<slug>/HANDOFF.md` | the session's task: the user's specific instructions (quoted), worktree + base SHA, sources (artifact/brief/plan), traps, migration range, sub-agents, "Done means" | controller |
| `INTERFACES.md` | append-only `- <UTC> (<session>): …` — contracts/schemas, Redis key formats, migration numbers, changed shared lines, "ready to use" status; read before every merge; never `sed -i` it | all sessions |
| `<slug>/PROGRESS.md` | appended per milestone (UTC, done + SHA, next) + a **Decisions** list | session |
| `<slug>/E2E.md`, `RELEASE.md` | test evidence; release steps | session |
| `<slug>/DONE`, `DEPLOYED` | final branch + SHA per repo, PR, E2E/RELEASE summary, open items; release marker | session |
| `DEPLOY-LOG.md`, `locks/`, `bin/lock` | §6.5 | shared |
| `DEPLOY-PLAN.md` | release order across sessions (starts after which marker, contents, completion marker) | controller |

### 8.3 Launching sessions

One isolated process per session (e.g. screen + a systemd scope on a shared VM) with a clean env and a short prompt that
points to `HANDOFF.md`; a memory limit with an OOM policy that does not kill the whole group; sessions are launched one
at a time. After a reboot: relaunch, or `claude --resume <transcript>`; check for stale locks first.

| What the user says | Meaning |
|---|---|
| "buat sesi baru (namanya X)" ("create a new session (named X)") without a task | an **empty** session for a new topic; the current session keeps its role |
| "lanjutkan (pekerjaan ini) di sesi baru dengan <model> effort max" ("continue (this work) in a new session with <model> effort max") | **launch** a session with a HANDOFF.md; the current session only prepares it |
| "lanjutkan lagi pekerjaan X dengan sesinya" ("resume work X with its own session") | `claude --resume <id>` of the old session |

### 8.4 Controller

Prepares the batch folder, allocates resources, sets the **merge order** and the **touch points** between plans,
creates worktrees, launches sessions; monitors `DONE`, `INTERFACES.md`, whether sessions are alive, disk & RAM; relays
cross-session findings; once everything is `DONE`, launches the integration session and reports. Deploys only when the
user says deploy, following `DEPLOY-PLAN.md`. Re-reads every peer's `DONE` right before integration.

### 8.5 Sub-agents

- The number running at once per session is capped (2–3; 0 when quota is thin).
- Rules: own worktree & branch; state in `<session folder>/<track>/`; **never** touch production, main branches,
  deploys, or infra; may push their own branch as a backup; do not spawn further sub-agents; no `git stash`; own ports
  & DB; the parent session's trailer.
- Final report: branch + worktree + SHA; test results (unit, e2e per case, proof on master, clients); migrations
  (destructive or not); decisions & deviations from the plan; remaining work; **"READY TO MERGE" or not, stated
  plainly**.
- Replacing an agent that was cut off: the old agent commits + writes a HANDOVER section; the new agent reads its
  transcript.

---

## 9. Communicating with the user

- **Reply in the user's language, concisely.** Artifacts follow §4.7.
- **Few questions.** Make product decisions yourself from the artifact/brief/plan, with the plan's recommendation as
  the default, and record them in the plan and the final report. Still ask about: production commands that
  delete/overwrite data, production approvals not yet given, decisions that truly block a package. Bundle them into
  **one** question with several items, each with a **recommended option**, no sub-questions; do not block other work
  while waiting.
- **Build so that reversing a decision is cheap**: keep all decisions in one place; do not bake optional workflow states
  into a migration before the decision is settled (the user once reversed a decision mid-build).
- **Estimate in agent time**, not human work weeks. Call out separately only what cannot be sped up: production
  approvals, blocking product decisions, time-bound waits — and ask for them all at once at the start.
- **"deploy" from the user = do it without asking again**, with the per-repo meaning (see the project's `AGENTS.md`);
  one exception: confirm before the first push to master if auto mode blocks it. "push dulu saja, jangan langsung
  merge" ("just push for now, don't merge right away") = push the branch without merging.
- **Final report:** per repo the branch, worktree path, final & live SHA, PR URL; production migrations (number, time,
  backup), deploy runs, verification results; E2E summary (numbers, FAIL-set diff, proof on master); decisions taken;
  **what is not done / still open**. Report only facts that were checked directly.
- An unreadable user artifact link: ask for an export (e.g. a "save page" ZIP) and extract it into the batch folder; do
  not stall. Results the user needs to read outside the chat are published as an artifact/document.

---

## 10. Recommended improvements for new projects

Lessons from inconsistencies seen in production systems. Apply them from the start unless the user decides
otherwise:

| Improvement | Reason |
|---|---|
| **Migration history table** (`schema_migrations(filename, checksum, applied_at)`), filled by each migration or a small runner | Without it the latest migration has to be guessed from the schema |
| **Switches with safe defaults**: empty = `off`/`log`, or the server refuses to start without an explicit value | An empty switch = `enforce` once shut a feature instantly at deploy |
| **CHANGELOG cut per deploy**: live entries move from `[Unreleased]` to `## [YYYY-MM-DD] deploy <sha7>` | Otherwise `[Unreleased]` fills up with entries that are already live |
| **A fixed list of CHANGELOG tags** (§3) | Duplicate tags (`[NOTIF]`/`[NOTIFICATION]`) |
| **One language for `docs/reference`** | A mix of English/Indonesian makes searching hard |
| **A clear git bot identity** for agent commits | Agent commits carry the machine's default author |
| **A semaphore log separate** from `DEPLOY-LOG.md` | Hundreds of semaphore lines drown out the production steps |
| **Local Postgres version = production** | The local version was once stated inconsistently across documents |
| **A cross-machine deploy lock**: `concurrency` in the workflow + a shared release log | The `mkdir` lock only works on one VM |
