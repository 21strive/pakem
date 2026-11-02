# 07 — Testing & E2E

There is no backend staging. Confidence before production is built from: unit & guard tests in `go test ./...`, cache
parity tests, **black-box HTTP E2E against a local stack that uses the production schema**, **full-suite regression of
the master binary vs the branch binary**, migration tests on a production dump copy, and client tests against the local
backend.

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Test layers

| Layer | Tool | Contents |
|---|---|---|
| Usecase | testify + mockery mocks (grouped in a struct) | business logic; assert on `*helper.ErrorLog`; **ownership: another account's resource is rejected and nothing is written**, the caller's own resource succeeds. `TestMain` sets `ENVIRONMENT=local` |
| Repository | `go-sqlxmock` (SQL matched by regex) + `miniredis` | **MUST** `ExpectationsWereMet()`; complements tests against a real Postgres, does not replace them |
| Validator | a real Fiber app | `Locals("user")` = the attacker; a body with **every spelling of the identity keys** (`useruuid`, `UserUUID`, `userUuid`, `USERUUID`, `user_uuid`, Unicode folding) → always the caller's identity |
| Route | stub controllers | static-before-param lands on the right handler |
| **Guard tests** (AST / configuration, part of `go test ./...`) | — | `TestArchitecture` (imports per layer, no `http.Status*` in the inner layers, only `responses` maps kinds; the baseline only shrinks), `TestErrorLogCalls` (sentinels, no baseline), `TestEveryAuthenticatedRouteDeclaresItsAccess`, `TestEveryAdminRouteChecksAdminAccessFirst`, `TestRedifuCachesTakeAGeneration`, `TestRedifuKeyFormats`, `TestMainHttpHandlerCORSOrigins` |
| Cache parity (unit) | real Postgres + miniredis | [04-caching.md](04-caching.md) §8.1 |
| Migration literals vs code | read the SQL files | data hard-coded in migrations equals the Go constants |
| HTTP E2E | `scripts/e2e` (its own Go module) | §3 |
| Cache parity (e2e) | `scripts/e2e/redifu_parity*` | [04-caching.md](04-caching.md) §8.3 |
| Clients | vitest, eslint/prettier, Playwright; `flutter analyze/test` | §8 |

- Parallelism on a shared machine: `go test -p 2`; `-p 1` when two packages drain the outbox table of the same test DB.
- Tests that need a real Redis (HyperLogLog, `PFMERGE`): `REDIS_TEST_ADDR` with a separate DB per package.

## 2. Baseline: compare the FAIL-set, not the exit code

- **MUST** save the list of tests that **already fail on master** as the baseline, then compare the branch's **set** of
  `--- FAIL` against it. Branch-only FAILs = 0.
- A package that panics is run **test by test** so the FAIL-set is complete (a panic hides the rest of that package's
  tests).
- Clients have a baseline too (the number of lint/analyze issues and red tests on the main branch).
- **(improvement)** new projects keep master green from the start; tests that depend on the date/time are made
  deterministic.

## 3. E2E suite design (`scripts/e2e`)

- **Black-box HTTP** against a running server; its own Go module (`scripts/e2e/go.mod`), a small client (`client.go`:
  `Get/Post/Patch/Delete`, token, headers, request/response logging that can be turned off).
- `TestMain` logs in once as the "suite owner" (`E2E_BASE_URL`, `E2E_EMAIL`, `E2E_PASS`); every `TestX` fetches its own
  prerequisites so the suite stays self-contained.
- **Accounts:** tests create their own accounts through **shared helpers** (`newPerson`, `signIn`, `switchTo`, `onboard`,
  `inviteAndJoin`), with unique emails (`…e2etest…@test.local`) and passwords that satisfy the policy. **Accounts are
  created only through the helpers**, never with a direct `POST /user/register` — a new gate (email verification) then
  only needs a change in the helper.
- **DB:** read through `localDB(t)` = `E2E_DATABASE_URL`; **MUST NOT** ever point anywhere but a local DB; without that
  env the test is skipped.
- **Email:** read from a **file sink** (`waitForEmail` reads `E2E_EMAIL_SINK_DIR` = the server's `EMAIL_SINK_DIR`; one
  JSON per email, written as `.tmp` and then `rename`d). The server rejects the sink outside `ENVIRONMENT=local`.
- **Third-party fakes** (`scripts/e2e/fake{google,zoom,s3,logs}`): URL overrides are honored only when
  `ENVIRONMENT=local`; controlled through `/_fake/*` (revoke, expire, force 401, events, calls); fake accounts are named
  in the authorization code (`fake:<sub>:<email>[:option]`). Payment gateway: a stateless stand-in + a webhook helper
  signed with the stand-in's secret.
- **Test file header:** the plan & the sections under test, the list of case IDs + expected behavior, the env needed, and
  **"On master these fail: …"**.
- **Subtests are named with the case ID:** `t.Run("T2 V14: a payment of charges alone opens …")`.
- Test data comes from the source of truth in `scripts/e2e/testdata`.
- **SHOULD** seed through the public API (register → setup → onboarding); SQL seeds only for what cannot go through the
  API, and they must also fill the side tables and the index outbox.

## 4. Local E2E stack (`scripts/e2e/local`)

Template: [`templates/backend/e2e-local/`](../templates/backend/e2e-local/) + the `make` targets in
[`templates/backend/Makefile`](../templates/backend/Makefile).

```bash
make e2e-db-reset && make e2e-up && make e2e && make e2e-down
make e2e E2E_ARGS='-run TestWidget -timeout 90m'
```

- **`db-reset.sh`:** `dropdb`/`createdb` → **production schema snapshot** (`schema_prod_<date>_post<NNN>.sql`, no rows)
  → every numbered migration > `SCHEMA_LEVEL` (one `psql` per file, autocommit — exactly like production; `CONCURRENTLY`
  files cannot run inside a transaction) → `seed.sql` (reference data only) → flush the e2e Redis.
- **`up.sh`:** build the binary; the e2e stack's own `redis-server` (`--bind 127.0.0.1 --save '' --appendonly no`); `.env`
  is **generated** in `$E2E_RUN_DIR` (never `.env.local/.env.staging`, which point at remote hosts): `ENVIRONMENT=local`,
  DB via socket + dummy password, `POSTGRES_SSLMODE=disable`, pools = production (10/10), dummy `JWT_API_SECRET`,
  `EMAIL_SINK_DIR`, `WHATSAPP_ENABLED=false`, `PUSH_ENABLED=false`; optional fakes per port; `env.extra` appended at the
  end (local Typesense, gateway stand-in); server + notification worker + `E2E_EXTRA_WORKERS` run in the background with
  pid files; wait for `/health`.
- **`down.sh`:** stop **by PID** (never by pattern).
- Per-session overrides: `E2E_PORT`, `E2E_REDIS_PORT`, `E2E_DB`, `E2E_RUN_DIR` (default `<worktree>/.e2e`).
- **MUST** the harness env = the relevant production env, including **feature switch values** (without
  `QUEUE_ENABLED=true` every queue test fails with 404) and **(improvement)** `POSTGRES_BINARY_PARAMETERS=true`.
- **MUST** keep `seed.sql` in step with new data migrations (the seed runs after the migrations, when the data migrations
  had no rows to act on yet).
- Pitfalls: the default `go test` timeout of 10 minutes silently cuts the full suite short (`-timeout 90m`); through
  `make`, `$` is written `$$`; `go test -v ./...` holds back output until the package finishes.
- Fiber listens on `0.0.0.0` — run the stack only while testing and shut it down afterwards.

## 5. New tests must FAIL on the master binary

This proves the baseline really runs the old code. If a new test passes on master, the binary swap failed and the
comparison is void. Check for **an explicit FAIL, not a SKIP** (a test that "skips if the server does not have the
feature yet" hides this problem). Example: the group-session suite fails on master during setup
(`PUT /service/:uuid/group-session` 404) and passes 18/18 on the branch.

## 6. Full-suite regression: master vs branch

1. Build a binary from `origin/master` and one from the branch.
2. For **each**: drop & rebuild the DB, flush Redis, delete the Typesense collections, keep env & workers exactly the same
   (including production flags).
3. Seed the suite owner, run the full suite, save the sorted `--- FAIL` lines.
4. **Compare the sets:** branch-only FAILs must be 0; master-only FAILs = the new tests; for FAILs common to both sides,
   also compare at assertion level (file:line + message, IDs & numbers normalized).

Run validity:

- Compare the `RUN` counts of both sides (a baseline once silently lost its seed: 621 vs 935 RUN).
- One panicking test stops `go test` — run the rest test by test and add them to the FAIL-set.
- Search the run logs (worker logs included) for `too many clients` — an affected run is repeated, not counted.
- Clock-dependent tests (the day has already rolled over in the business zone) are re-run on **both** binaries back to
  back.
- The binary swap must not be able to fail silently ("Text file busy" once caused the branch binary to be tested twice)
  — copy the binary into the run dir.
- One binary takes ±50 minutes for ±1,000 tests; regression slots are limited per machine.

Example of a reported result: "master 951/850/57/44 vs branch 1043/941/57/45 RUN/PASS/FAIL/SKIP; identical FAIL-set,
identical assertions; 92 new (sub)tests PASS".

## 7. Migration tests

1. Restore the latest production dump into a new local DB (`pg_restore --no-owner`).
2. Run the migrations that reached production after the dump, **in production order** (including any backfills in
   between).
3. Run your migration; record the run time; run it **once more** (idempotent); count the affected rows.
4. Make sure the old code still runs on the new schema (code × schema matrix, [02-database.md](02-database.md) §4.8).
5. Data migrations: a per-JSON-path diff or a per-row md5 before/after; a `DO` block that rolls back if any row is left
   unreached; test the rollback from a `\copy` CSV.

Example report: "100 in 0.05 s, 101 in 0.04 s; both re-run cleanly (idempotent); 140 services → kind SERVICE".

## 8. Client tests

- **Web & dashboard:** `npx vitest run` (`--maxWorkers=2`); eslint + prettier on the changed files; `vite build` (asset
  hashes match Pages → can be compared with the live bundle); **Playwright** for the main flows against the local branch
  BE.
  - The local BE's CORS allows only `http://localhost:5173`: run Vite with `--host localhost --port 5173 --strictPort`
    while holding the **port lock** (one user per machine); **MUST NOT** commit CORS changes made for e2e.
  - API calls from Node go to `127.0.0.1`, the browser uses `localhost` (Fiber is IPv4 only).
  - Screenshots go in the session folder (`<session>/e2e/`).
- **Mobile (Flutter):** `flutter analyze` vs the main-branch baseline; `flutter test` (`--concurrency=2`) FAIL-set vs the
  baseline; repository/cubit tests against a real local BE (`HttpOverrides.global = null`) or model parsing with real
  response JSON as fixtures; alternatively `flutter run -d web-server` + Playwright. No emulator on the VM.
- **Screenshot harnesses** (visual evidence, **not committed**): web — the repo's harness with a mock API and Playwright
  Chromium; dashboard — a node mock server + Vite + Playwright with loading/error/empty scenarios; Flutter — golden tests
  with real fonts (`--update-goldens`). "Before" shots come from a detached worktree on the main branch. Data from a
  production copy is **anonymized** first. Linux WebKit ≠ iOS Safari — for SVG sizing bugs, test the layout boxes, not
  the pixels.

## 9. Review after E2E

`/code-review` at a high effort level on the final branch diff, or reviewer sub-agents per area with a time limit (make
sure the reviewers actually report back). Fix the findings, re-run the affected tests, record "review fixes" in the plan
status.

## 10. Evidence: `E2E.md` (session folder)

Template: [`templates/session/E2E.md`](../templates/session/E2E.md). Minimum contents: the branch per repo + the SHA of
the main branch already merged in; unit FAIL-set = master; guard tests; new e2e N/N on the branch and the point of
failure on master; full regression table per binary; migrations on a dump copy (time, idempotent, counts);
web/dashboard/mobile; an explanation of the shared FAILs.

## 11. Audits are proven with failing tests

Audit findings (security, time zones, consistency) are proven with e2e tests that **fail on master** — one test per
defect + file:line in the report. The fix turns that test green.

## 12. CI

- **(improvement)** backend CI runs `go build ./...`, `go vet`, `go test ./...` (all guard tests), `worker --check`, and
  replays every migration on an empty Postgres twice — before deploy — a deploy workflow that runs no tests leaves
  everything to local runs.
- **(improvement)** a secret scanner (gitleaks) in CI.
- The full e2e suite still runs locally/in sessions (it needs the stack, ±50 minutes per binary).
