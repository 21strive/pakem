# 00 — Principles and core decisions

A summary of the decisions that shape every other document. When in doubt while designing something, come back to this
list. Each item links to the document that explains how and why.

These are decisions about **how the backend is built**. Pakem does not decide which products or services it runs on —
cloud, managed database, CPU architecture, container platform, CDN, storage, email, logs: those belong to the project
(§F 22).

## A. Data

1. **PostgreSQL is the only source of truth.** Redis is only for a rebuildable cache, short-lived state (short TTL; losing
   it only resets a limit or makes a user repeat one step), and a buffer a worker copies to Postgres every pass. Test before
   adding a key: *"if Redis were FLUSHALLed now, would any number in Postgres, any email, or any bill be wrong?"* If yes,
   store it in Postgres first. → [04-caching.md](04-caching.md) §1
2. **Queues and locks live in Postgres** — outbox tables (`redifu_outbox`, `notification_outbox`, `search_index_outbox`, …)
   and advisory locks. Never use Redis lists/`SETNX` for either. → [05-workers-and-integrations.md](05-workers-and-integrations.md)
3. **The schema changes through numbered SQL migrations**, run by hand against production with approval, in the order
   **expand → deploy → contract**: add first (nullable/defaulted columns, tables, `CONCURRENTLY` indexes), deploy the code
   that uses it, remove later once nothing uses it — and removal always needs explicit approval. → [02-database.md](02-database.md)
4. **Money is stored as an integer** (`bigint`/`int64`) in the agreed whole currency unit (e.g. whole rupiah); other
   units (cents) are named in the field (`…_minor`). Never float. Float amounts from third parties are rounded to the nearest
   smallest unit only when the difference is clearly float representation noise, and rejected when they truly carry a finer
   fraction. → [02-database.md](02-database.md) §1.6
5. **Time is stored and processed in UTC** (`timestamptz`, `time.Local = time.UTC` in the process). A user's/business's time
   zone is data, used explicitly when computing "today", schedules, and message text. → [03-api-design.md](03-api-design.md) §8

## B. Code

6. **One Go binary, three modes** (`main`, `worker [name]`, `command <name>`), one image for all of them.
   → [01-architecture.md](01-architecture.md)
7. **Strict layers enforced by tests**: Route → Middleware → Controller → Validator → UseCase → Repository. Controllers and
   middleware never call a repository; only `app/responses` knows HTTP statuses; repositories never import HTTP DTOs. The
   violation baseline only shrinks.
8. **A usecase = one business capability**, owner of the transaction, and **ownership checker**: every resource identified
   by client input is confirmed to be the caller's before it is read or written; "does not exist" and "not yours" get the
   same answer (404). Writes on user-owned rows carry the owner in the `WHERE` as a second layer.
9. **Errors are kinds, not statuses.** 4xx messages are written for the client (sentinels in `app/constants`); 5xx are masked
   as `"Internal server error"` + `error_id`; driver text never reaches the client.
10. **DI through Providers**: every repository/usecase is built once at startup.

## C. Cache

11. **The write path does not know the cache exists.** A Postgres row trigger records every change of a watched table into
    `redifu_outbox` in the writer's transaction; a per-owner drain applies it to Redis. No Redis writes from requests, no
    manual purges when content changes.
12. **One datum, many references**: each entity is stored **once** (one key per uuid); lists/indexes hold only uuids. A change
    to one entity shows up in every view at once.
13. **Reading from the cache = a decorator** over the SQL repository that answers **exactly** like SQL (structure, columns,
    order, errors) and falls back to SQL whenever the cache cannot answer. Emergency switch `REDIFU_READS=false`.
14. **Generations + lease**: only the newest build uses the cache; a change in the shape of the data automatically
    invalidates old values; deploys and rollbacks need no manual step. → [04-caching.md](04-caching.md)

## D. API

15. **One response contract** for success and error, with `trace_id` in a header and `error_id` for 5xx.
16. **Every risky feature has a switch** (env `*_ENABLED`): off = routes answer 404, instant rollback without a deploy and
    without a data change.
17. **API documentation is a deliverable**: Swagger annotations + a manual Postman collection + a handoff prompt for the
    frontend/mobile teams. A feature is not done until all three exist. → [03-api-design.md](03-api-design.md)
18. **Files never go through the API.** Clients upload straight to object storage with a presigned PUT; private files are
    read with a short-lived presigned GET after an access check. → [09-frontend-and-storage.md](09-frontend-and-storage.md) §4

## E. Side effects & integrations

19. **Outbound side effects go through an outbox + worker**, never inside the request transaction: email, WhatsApp, push,
    the search index, image rendering, retryable third-party calls. Workers are idempotent and can be repeated.
20. **Every delivery channel has a kill switch**, and a misconfigured channel must never silently send to the wrong place.
    Nothing real (messages or money) can be sent from a local environment.
21. **Every third-party integration has a local fake/stand-in** for E2E (OAuth, storage, logs, payment gateway).
    → [05-workers-and-integrations.md](05-workers-and-integrations.md)

## F. Infrastructure & releases

22. **Products and services are the project's decision, not the blueprint's.** Pakem fixes the roles and what each must
    do — one image as an API service and a worker service behind a load balancer that only the edge can reach; Postgres
    behind a pooler; Redis; a private search engine; S3-compatible object storage; static frontend hosting with an edge
    function; one fixed egress IP — and the project picks the cloud, managed services, CPU architecture, and providers
    that fill them, recording each choice in its `AGENTS.md`. The
    [case study](../case-studies/aws-supabase-cloudflare/README.md) shows one such set; it is an illustration, not a
    default. → [08-infrastructure.md](08-infrastructure.md), [09-frontend-and-storage.md](09-frontend-and-storage.md)
23. **All infra is code** in a separate infra repo; non-secret settings committed with comments that explain their reason
    and history; secrets in a secret store (only names in the repo); CI uses federated, short-lived credentials (OIDC),
    never static keys.
24. **Backend deploys are manual and controlled** (`workflow_dispatch`), one at a time, verified until the new tasks run the
    right image. Backend first, clients next.
25. **No mandatory backend staging.** Validation = local E2E against the production schema (+ a dump copy for migrations) and
    a full-suite regression against the master binary; risky releases go to production behind a switch.
    → [07-testing-and-e2e.md](07-testing-and-e2e.md)

## G. Ways of working

26. **Every piece of work in a new worktree + branch**, never in the main checkout or on the main branch.
27. **Docs are part of the change**: `docs/reference` is always true against `master`, `docs/plans` carries a status, the
    CHANGELOG is updated with every visible change.
28. **Production needs approval**: migrations/backfills/commands that change production data only with the user's approval;
    anything that deletes or overwrites data is always asked, with the command, its impact, and the row count.
29. **Few questions, clear defaults**: ask only decisions that change what gets built, a few at a time, each with a
    recommended option; decide the rest, record it, move on.
30. **Languages**: code, comments, commits, CHANGELOG, API error messages, and documentation in English; end-user text in the
    product's language; replies to the user in the user's language. → [10-workflow.md](10-workflow.md)
