# 05 — Workers, commands, outbox, notifications, search, integrations

Every effect outside the system (email, WhatsApp, push, search index, image rendering, statistics projections, cache
invalidation) is carried out by **workers** that drain **outbox tables in Postgres**, written in the same business
transaction. There is no message broker. This document standardizes the shape of workers & commands, the outbox pattern,
the multi-channel notification system, Typesense search, and third-party integrations.

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Workers & commands

### 1.1 Modes and dispatch

- One entrypoint: `go run ./app/cmd main | worker [name] | command <name> [args]`. `worker` without a name starts **all**
  workers in one process (each in its own goroutine); `worker <name>` starts just that one; `command` runs to completion.
  Worker/command names = centralized string constants (`WorkerNotification = "notification"`).
- In production: one ECS worker service runs `worker` (desired 1).
- `Init*Worker` (`app/workers/init_worker.go`) = per-worker DI; `Start*Worker` = its loop. Signal wrapper:
  ```go
  func runWithSignal(ctx context.Context, name string, startFn func(context.Context)) {
      signalExit := make(chan os.Signal, 1)
      signal.Notify(signalExit, os.Interrupt, syscall.SIGINT, syscall.SIGTERM)
      workerCtx, cancel := context.WithCancel(ctx)
      defer cancel()
      startFn(workerCtx) // each Init*Worker builds its dependencies, spawns goroutines, then returns
      <-signalExit
  }
  ```
- **MUST**, for a feature worker whose switch is off: do not wire it in "all" mode; in named mode, `return` immediately
  with an Info log (an idle process that looks like a running worker is misleading). A worker that still has cleanup work
  while the feature is off stays wired.
- **MUST** run commands that do not touch DB/Redis/R2 (rendering templates, provider operations, local table setup)
  **before** connections are opened (`CommandNeedsNoConnections(name)`); they receive `nil` for every handle.
- The first log line of every process: `<app>: build revision=<sha> built_at=<t> mode=<m>`.
- **(improvement)** one **registry** `name → {help, needsConnections, run}` that also generates the help (a list
  printed in several places, or a worker count in an infra comment, goes stale).

### 1.2 Loop shapes

| Shape | When | Example values |
|---|---|---|
| Fixed ticker | draining light queues | notifications 10 s (expand 100, deliver 50); search-indexer 10 s / 100; image rendering 10 s / 20; cleanup 1 min |
| Self-paced (full batch → go again immediately, otherwise wait for the interval) | the backlog can be large | statistics projection idle 3 s / 200; marketplace listing 10 s / 500 |
| Timer + initial delay + `Reset` | heavy passes; do not compete with traffic during a deploy | error tracker 10 s then 1 min; account deletion 1 min then 2 min |
| Wall clock | business schedules | settlement 13:00 in the business zone + catch-up 2 min after boot |

```go
go func() {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()
    log.Info("x_worker: started", "interval", interval, "batch_size", batch)
    for {
        select {
        case <-ticker.C:
            n, errLog := uc.DrainOutbox(batch)
            if errLog != nil {
                log.Error("x_worker: drain failed", "error", errLog.Err.Error())
            } else if n > 0 {
                log.Info("x_worker: drained", "count", n)
            }
        case <-ctx.Done():
            log.Info("x_worker: stopped")
            return
        }
    }
}()
```

- **MUST** keep one failed item from bringing down the batch: each item runs in its own transaction; a failure is logged,
  then `continue`.
- **MUST** recompute a wall-clock schedule from the clock after each pass (`time.Date` for the next date), not `+24h`
  (drift) — name the zone and `import _ "time/tzdata"` (the runtime image has no tzdata); failing to load the zone = the
  worker does not start (never silently fall back to UTC).
- **MUST** put periodic retention/cleanup in a **worker loop** (daily timer, first run ±5 minutes after boot) or in a
  **Terraform-managed scheduled task**. **MUST NOT** just write "daily cron" in the help — a command that is only
  documented as "daily" never runs.
- **MUST** give every per-item I/O its own time limit (`http.Client{Timeout}` / `context.WithTimeout`): object storage
  30 s (deletes inside a request 10 s), WhatsApp 20 s, push 15 s, OAuth 15 s, Maps 8 s, payment library 40 s. The S3/R2
  client has no HTTP timeout of its own and the SDK retries — one slow object can hold up a tick.
- Multi-step workers: each failed step is logged and the next step still runs; check `ctx.Done()` between steps.
- **Workers that guard a business invariant** still emit an ERROR when the invariant is violated, even though the loop is
  healthy (e.g. "money awaiting settlement exceeds the age limit") — that ERROR line is what the error tracker catches.

### 1.3 Boot: fail-fast vs degrade

- **Fail-fast** (`os.Exit(1)`) for configuration that is certainly wrong: a template fails to parse/validate, the email
  sender address is empty, a channel's template map is invalid, a channel client fails to build while the channel is
  enabled, a duplicate sender in the registry, the catalog names a channel that has no sender. Reason: "enabled but
  unconfigured" produces one credential error per message, which reads like a provider outage and burns the retry budget.
- **Know the cost in the combined process:** `worker` without a name = one process → one worker's `os.Exit(1)` kills
  **all** workers (email, settlement) and ECS crash-loops. That is why the release order is recorded in tfvars: deploy the
  image that carries the catalog change **first**, then apply the env that turns the channel on; fill SSM **first**,
  before the task definition references it.
- **Degrade loud** for integrations that may be absent: no payment library → the settlement worker logs `slog.Error` and
  does not start; error tracker without its table → Warn, then return.
- **(improvement)** a `worker --check` that builds every `Init*` without starting them, run in CI — catalog/template
  mistakes surface before the deploy, not as a crash-loop.

### 1.4 Shutdown, instances, panics

- If SIGTERM cancels the context and the process exits **without waiting** for the running tick, this is safe
  **only because** every queue uses claim + reaper + idempotency (§2). **(improvement)** a `sync.WaitGroup` per worker +
  wait for the tick to finish, with a limit below the ECS `stopTimeout` (default 30 s).
- **Correctness does not depend on a singleton.** There is no leader election: workers are correct even when running
  as > 1 instance (`SKIP LOCKED` claims, compare-and-set updates, conditional writes, deterministic references to the
  gateway). Being a singleton is only an ECS deploy concern (desired 1, min 0% / max 100%, circuit breaker).
- **Per-key** exclusivity uses a transaction-level lock: `SELECT pg_try_advisory_xact_lock(hashtextextended('<ns>:' ||
  $1, 0))` in a short transaction; failure = skip that key, the next pass retries it. **MUST NOT** use session-level
  locks/`SET` behind a transaction pooler.
- **(improvement)** a panic in one worker goroutine kills the whole worker process (and with it every other worker).
  Wrap every tick:
  ```go
  func safeTick(name string, fn func()) {
      defer func() {
          if r := recover(); r != nil {
              // a format the error tracker counts as a PANIC, plus a stack to read
              fmt.Fprintf(os.Stderr, "panic: %s: %v\n\n%s\n", name, r, debug.Stack())
          }
      }()
      fn()
  }
  ```

### 1.5 Logging in workers

- Message `"<worker>_worker: <event>"` + kv fields; the "started" log carries the interval/batch.
- **MUST** write **no log** on a tick without work (CloudWatch cost + noise).
- **MUST** log the observer's own failures (e.g. the error tracker failing to read logs) as WARN, not ERROR (so they do
  not become a new error group every minute).
- Money amounts in logs are in human units (`4000.16`, not `400016` cents).

### 1.6 Commands (one-off)

- Each command parses its own flags (`flag.NewFlagSet(..., ContinueOnError)`); the dispatcher passes on `args[2:]`.
- **MUST use safe defaults matched to the level of danger:**
  - irreversible (moves money out): **report-only unless `--commit`**, a small limit (`--limit 10`), a minimum age
    (`--min-age 15m`, young rows may still be in flight), `--id a,b` for specific targets; the dry run ends with
    "Re-run with --commit";
  - destructive but countable: `--dry-run` (e.g. `redifu-purge` counts keys per format);
  - cannot be previewed: the runbook includes a query that measures the backlog + the smallest flags
    (`--batch-size 1 --max-passes 1`).
- **MUST** **reject** invalid flag values, not clamp them.
- **MUST** be idempotent; read-then-modify uses the **write pool** (candidates from a lagging replica can offer rows that
  were already processed → double transfer).
- **MUST** make a money-moving command refuse to run when the gateway is not configured (a fake success is worse than a
  refusal).
- **MUST** clearly label commands with third-party effects in the help (sends paid messages; registers templates that
  cannot be undone).
- Running in production: as a one-off ECS task with the same image, or from an operator machine with inline env (`.env`
  must exist; inline env wins). Commands use up the pooler's connection quota → small pool
  ([02-database.md](02-database.md) §6.4).
- **MUST** remove secrets that travel in notifications (reset links, verification codes) from the outbox payload once
  they expire — their own tables store only a hash, so the outbox payload is the only place the raw token is written.

---

## 2. The outbox pattern

### 2.1 Universal rules

- **MUST** write the outbox row in the **same transaction** as the business change, through a repository method that
  takes a `*sqlx.Tx`. The producer's entry point rejects `tx == nil`:
  ```go
  func (u *notificationUsecase) Enqueue(tx *sqlx.Tx, req requests.NotificationEnqueue) *helper.ErrorLog {
      if tx == nil { // without a tx, the notification could survive a rolled-back transaction
          return helper.NewErrorLog(errors.New("notification enqueue requires the caller's transaction"), helper.KindInternal)
      }
      if _, ok := constants.NotificationAudienceConfig(req.NotificationType, req.RecipientType); !ok {
          return helper.NewErrorLog(fmt.Errorf("catalog has no entry for %s/%s", req.NotificationType, req.RecipientType), helper.KindInternal)
      }
      // recipient required; payload marshaled; available_at defaults to now(); INSERT in the caller's tx
  }
  ```
- **MUST NOT** call providers (email/WA/push/Typesense/render) on the request path for effects that can be deferred — the
  request only writes the intent. Deliberate exceptions: presigned URLs (no effect), and calls whose result the response
  needs (the payment gateway at checkout, with a timeout, outside the transaction).
- **MUST** read queues from the **primary** ("worker must see a row as soon as the transaction that wrote it commits").
- Changes that can come from any process (worker, webhook, library, `psql`) → outbox via a **DB trigger** (the
  `redifu_outbox` pattern, [04-caching.md](04-caching.md) §3).

### 2.2 Three variants

| Variant | Example | Row contents | Consumer | Idempotency | End of life |
|---|---|---|---|---|---|
| **Snapshot** (messages to humans) | `notification_outbox` → `notification_delivery` | JSONB payload frozen at event time, `dedupe_key`, `group_key`, `available_at` | EXPAND then DELIVER per channel | 3 layers (§2.6) | terminal status; purged after 90 days / 1 year |
| **Signal** ("this entity changed") | search index, statistics projection, listings, cache | entity id (+ operation) | reads the **current state**, then upsert/delete | document id = uuid; replay is safe; may arrive twice/late/out of order | deleted after processing |
| **Per-entity job** | OG card rendering | one row per entity (`UNIQUE`), the active `storage_key` | CAS claim → work → mark | content-hash object key; "unchanged" shortcut | `SUCCESS`/`FAILED`; requeue = UPSERT back to `PENDING` |

- Signal queues that need **coalescing**: take only rows aged ≥ N seconds (one burst of changes is processed once), then
  delete that entity's rows **up to the `maxID` that was taken** (rows that arrive during processing stay for the next
  pass).

### 2.3 Claim

```sql
UPDATE notification_delivery
SET status = 'PROCESSING', locked_at = $now, updated_at = $now, attempts = attempts + 1
WHERE uuid IN (
    SELECT uuid FROM notification_delivery
    WHERE status = 'PENDING'
      AND (next_retry_at IS NULL OR next_retry_at <= $now)
      AND ($channel = '' OR channel = $channel)   -- seam: per-channel workers without a schema change
    ORDER BY created_at
    LIMIT $limit
    FOR UPDATE SKIP LOCKED)
RETURNING <columns>;
```

- "Claim first, work later", one statement, on the primary. `attempts` is incremented at **claim** time (a worker that
  dies mid-send still uses up an attempt — it cannot loop forever).
- Per-row claim (job): `UPDATE … SET status='PROCESSING' WHERE uuid=$1 AND status='PENDING'` + check `RowsAffected`.
- Indexes for the claim queries: `(status, available_at)`, `(status, next_retry_at)`, `(channel, status, next_retry_at)`,
  `(status, id)`, partial `(group_key) WHERE status='PENDING'`, `(status, updated_at)` for purges.
- **(improvement)** **every** queue uses claim + `locked_at` (an indexer that reads from a replica without
  claiming is safe only as long as there is a single worker).

### 2.4 Retry, backoff, dead letter

- **MUST** classify failures in the adapter: **`PermanentError`** = *this* message will never be delivered (invalid
  address, dead device token, number not on WhatsApp, payload missing a template field) → straight to `FAILED` without
  consuming budget; **`RetryableError`** = everything an operator can fix within minutes (credentials, quota, throttling,
  paused account, unverified identity, 5xx, network). **Unknown error = retryable** (degrade from "lost" to "late").
  Ruling an operator outage permanent throws away the entire backlog.

| Queue | Budget | Backoff |
|---|---|---|
| Email delivery | 5 | standard 1m, 5m, 30m, 2h, 24h |
| Push / WhatsApp delivery | 3 | standard |
| In-app inbox delivery | 5 (mandatory) | standard |
| Time-bound messages (reminders 24 h and 1 h before a session, payment instructions) | email 3; push & WA **2** | **short 1m, 5m, 15m** (a reminder that arrives after its session has passed is worse than silence) |
| Outbox expand | 5 | standard (repeated failure = bug) |
| Render job | 5 | 1m, 5m, 30m, 2h, 24h |
| Signal queues | 5–10 | **(improvement)** use `next_retry_at`, not every tick |

- Budget/backoff are read per **channel** from the catalog (email retries are free; WA retries can be billed).
- Dead letter = `FAILED` status on the same row, `last_error` + `last_error_kind`, kept for a long time (1 year) — the
  most valuable diagnostic material.

### 2.5 Reaper

```sql
UPDATE notification_delivery SET status='PENDING', locked_at=NULL, updated_at=$now
WHERE status='PROCESSING' AND locked_at IS NOT NULL AND locked_at < $now - interval '5 minutes';
```

Interval 1 minute; the lock timeout (5 minutes) **must be much longer** than any provider timeout. Logged as WARN (a
reaped delivery may already have reached the provider). **MUST** give every queue with a `PROCESSING` status a
`locked_at` + reaper.

### 2.6 Layered idempotency

| Layer | Mechanism | Covers |
|---|---|---|
| 1 | `dedupe_key` UNIQUE, deterministic from the business identity `TYPE:<entity>:<audience>:<recipient>[:discriminator]` | the same event produced twice (repeated webhook, double submit) |
| 2 | `UNIQUE (notification_uuid, channel, COALESCE(recipient_member_uuid,''))` + `ON CONFLICT DO NOTHING` | expand repeated after a crash |
| 3 | `idempotency_key` = the delivery row's uuid, passed on to the provider | the worker dies after the provider accepted but before `SENT` was recorded |

- **MUST** **never** derive a dedupe key from a timestamp/random value; add a discriminator for types that are
  legitimately sent more than once per entity (`H24`/`H1`, the start date on a reschedule).
- **MUST** let a dedupe conflict revive only a `CANCELLED` row (incident: a booking moved 10:00 → 14:00 → 10:00 lost its
  reminder because the 10:00 key was still held by the CANCELLED row):
  ```sql
  INSERT INTO notification_outbox (...) VALUES (...)
  ON CONFLICT (dedupe_key) DO UPDATE SET status = EXCLUDED.status, payload = EXCLUDED.payload,
      available_at = EXCLUDED.available_at, attempts = 0, next_retry_at = NULL, last_error = NULL,
      locked_at = NULL, dispatched_at = NULL, group_key = EXCLUDED.group_key, updated_at = EXCLUDED.updated_at
  WHERE notification_outbox.status = 'CANCELLED';
  ```
- Outbox status `DISPATCHED` is **terminal** (later failures live on the delivery). Each delivery is finalized with its
  own write — **MUST NOT** use one transaction for several channels.
- Layer 3 differs per provider (SES has no idempotency token → tag `delivery_uuid` for bounce correlation; FCM uses the
  delivery uuid as the collapse key; the inbox uses `UNIQUE (notification_uuid, recipient)`).

### 2.7 Scheduling, cancellation, snapshots

- There is no second scheduling engine: a scheduled message = an ordinary row with a future `available_at` (the 24 h / 1 h
  reminders are enqueued when the booking is created; those whose time has already passed are **not** enqueued).
  Precision = the tick interval.
- **MUST** bulk-cancel per entity via `group_key = '<entity>:<uuid>'` in the transaction that cancels the entity; order:
  **`Cancel` first, then enqueue** the new messages in the same tx (if reversed, the cancellation notice gets cancelled
  too). `CancelTypes` cancels only some of the types.
- **MUST** snapshot the payload at event time; per-recipient data that may change up to send time (the host's time zone)
  is refreshed at EXPAND.
- **MUST** read payload keys that were added later with `{{with index . "Key"}}…{{end}}` in templates — rows queued
  before the deploy do not have that key.

### 2.8 Retention

Children first, parents last: deliveries `SENT/SKIPPED/CANCELLED` > 90 days, `FAILED` > 1 year (age from `updated_at`);
then terminal outbox rows that **no longer have any delivery** (an FK `ON DELETE CASCADE` would also delete FAILED
deliveries that must be kept); `PENDING/PROCESSING` are never touched; inbox > 90 days. Delete in batches of 1,000 rows,
repeat until a batch comes back short. **MUST** have every signal queue delete finished rows or apply a retention.

### 2.9 DDL & "why wasn't it sent"

DDL for the notification outbox + delivery: [`templates/backend/sql/notification_outbox.sql`](../templates/backend/sql/notification_outbox.sql).

**MUST** turn every "not sent" into a row with a reason, not drop it: `SKIPPED` + `NO_ADDRESS`, `CHANNEL_DISABLED` (the
operator turned the channel off), `OPTED_OUT` (the recipient turned it off), `NO_CHANNEL`, `NO_RECIPIENT`,
`ACCOUNT_PENDING_DELETION`. "Why didn't they receive it?" is answered with SQL:
`SELECT channel, status, skip_reason, count(*) FROM notification_delivery GROUP BY 1,2,3;`

---

## 3. Notifications (email, WhatsApp, push, inbox)

### 3.1 Model

- Two core tables: **outbox = intent**, **delivery = unit of work per channel × recipient**.
- **Recipient fan-out at produce time** (only the business domain knows who the recipients are); **channel fan-out at
  dispatch time**. Business usecases know only `Enqueue/EnqueueMany/Cancel/CancelTypes` and **do not know about
  channels**.
- Payloads are built **separately per audience** even when their contents are the same today (the host payload carries
  figures that must not reach the customer).
- **The catalog lives in code**, keyed by `(type, audience)` → `channels{Template, Mandatory, RetryBudget, Backoff}` +
  `Category`. Adding a type = constant + catalog entry + template directory + fixture, no migration. Adding a channel =
  one adapter + one registry line. What changes often ("turn WA off now") is handled by an env kill switch, not the DB.
- Audience = recipient class (determines channels, templates, payload shape): e.g. `USER` (account owner), `CUSTOMER`
  (no account → never push/inbox), `MEMBER`, `ADMIN` (email only).
- Channel resolution: catalog → the row's `channel_override` → recipient preferences (can only **remove**) → drop channels
  that have no adapter. Zero channels → `SKIPPED/NO_CHANNEL`.
- **Adapter port:** `Channel()`, `ResolveAddress(audience, uuid)` (empty = `SKIPPED/NO_ADDRESS`, not an error),
  `Send(ctx, req) (providerMessageID, error)`; optional `DisabledFor(audience)` (checked **before** resolving the
  address).
- The adapter is split in two: the **client** only translates the wire format (JSON request, provider error → sentinel),
  the **sender** owns the decisions (retry vs park, resolving the recipient, filling in parameters). The client is tested
  against a stub server.
- A **log** adapter proves the outbox machinery end-to-end before any provider is connected (not registered in prod).

### 3.2 Notification worker boot gate

1. every template parses; 2. `Validate()` executes **every** template against its fixture; 3. the email sender address
is set; 4. the WA template map is valid (`Validate(requireApproved = WHATSAPP_ENABLED)`); 5. the push data map is valid
(deep links point at fixture fields that exist; `<app>://` scheme); 6. the inbox map is valid; 7. the registry has no
duplicates; 8. `ValidateNotificationCatalog(senders.Channels())`. Failure → `os.Exit(1)` (§1.3).

### 3.3 Templates

- Embedded in the binary: `//go:embed all:templates` (the `all:` prefix is required, otherwise `_fixtures/` is skipped).
  Directory name = template key. Email = `subject.txt` + `body.html` + `body.txt`; push/inbox = `title.txt` + `body.txt`;
  WA = `body.txt` with the provider's positional placeholders.
- `body.html` is parsed with `html/template` (auto-escape), the rest with `text/template`; all of them with
  `.Option("missingkey=error")`. The per-type fixture (`templates/_fixtures/<type>.json`) holds **every** key the template
  touches = the payload contract. A render failure at send time = `PermanentError` (a producer bug).
- Images in email = absolute URLs to the asset CDN (not attachments, not inline SVG).
- `command notification-preview <template_key> [payload.json]` renders into a preview directory without DB/provider.
- **(improvement)** fill `template_version` (a hash of the template contents) on the delivery at render time — "what
  exactly was sent after the template was edited" must be answerable.
- Email designs may live in a separate design repo (HTML per design + previewer); the backend copies `body.html` with the
  example values replaced by Go placeholders; type names follow the design names so they can be reviewed side by side.

### 3.4 Preferences

One switch per (user, type), **no row = on**. Only non-mandatory channels (email, push) for the account-owner audience
can be turned off; the inbox is always mandatory. **One function** (`NotificationChannelOptOutable`) is used by the
settings endpoint **and** by EXPAND — the UI's promise = the worker's behavior. Read from the primary; a failed read =
EXPAND is retried. As soon as there are promotional notifications, an unsubscribe link is **required**.

### 3.5 Email — Amazon SES (SDK v2, not SMTP)

- `sesv2.SendEmail` with `Content.Simple` (Subject + Text + Html, UTF-8), From `"<Q-encoded Name> <no-reply@<domain>>"`.
  SMTP was replaced because all its failures are opaque strings (a dead address used up 5 attempts over ±27 hours) and
  `net/smtp` drops the MessageId (bounces cannot be joined).
- Credentials come from the ECS **task role** (the access key pair is **left empty** on AWS). SES has **its own client**:
  the process's `aws.Config` built for R2 (region `auto`) fails every send with symptoms that look like "an IAM problem".
- Narrow classification: only `MessageRejected` = permanent; throttling, quota, paused account, unverified identity =
  retryable.
- `EmailTags: delivery_uuid=<idempotency_key>`; `SES_CONFIGURATION_SET` once bounces/complaints are wired to SNS.
- IAM `ses:SendEmail` only, resource = the domain identity + `identity/*@<domain>` in the sending region (restricts the
  From address). `SES_REGION` = the Terraform region variable that forms the ARN.
- DNS via Terraform (verification, 3 DKIM CNAMEs — literal count 3, MAIL FROM, SPF, DMARC) and **request production
  access from day one** ([08-aws-infrastructure.md](08-aws-infrastructure.md) §4.7).
- Env: `SES_REGION`, `SES_FROM_ADDRESS` (required), `SES_FROM_NAME`, `SES_CONFIGURATION_SET`, `EMAIL_SINK_DIR` (local
  only, [07-testing-and-e2e.md](07-testing-and-e2e.md)).

### 3.6 WhatsApp (Meta Cloud API, directly or through a reseller)

- Business-initiated messages = **Meta-approved templates**. The repo stores the submitted body + the mapping (template
  key → approved name, category, language, payload field → position). The approved name is filled in **after**
  `APPROVED`; empty = not allowed to send yet. Boot validates body vs params and renders every template against its
  fixture **even when the channel is off**; the approval requirement applies only when the channel is on.
- Turning the channel on = all-or-nothing for the templates the catalog routes: if approvals come in stages, temporarily
  remove the WA entry from the pairs not yet approved (that commit must already be deployed before the switch is turned
  on — otherwise the worker hits `os.Exit(1)` and email dies with it). Entries awaiting approval are written as a comment
  block in the catalog together with their release steps.
- Layered kill switches: `WHATSAPP_ENABLED` (default false — a paid channel: a credential leak, wrong copy, or an enqueue
  loop must be stoppable without a deploy) and a per-audience pause, as sender **wrappers**. A disabled channel still
  writes `SKIPPED/CHANNEL_DISABLED` deliveries → volume is measurable at no cost.
- The sender phone number ID is set explicitly (when empty, the provider picks one itself — wrong as soon as there is a
  second number).
- Error classification: HTTP status first (401/403 retryable, 429 rate limited, ≥500 retryable), then the Meta code
  (number not on WA = permanent; params vs copy mismatch = repo bug; template missing/paused; rate limit). Unknown: WARN
  with the body truncated to **512 bytes**, then retryable.
- Meta limits: parameter ≤ 1,024 characters; body ≤ 1,024 measured on the template **definition** (not the rendered
  result); timeout 20 s; numbers normalized to E.164; the category (UTILITY/MARKETING/AUTHENTICATION) determines the price
  and how strict the review is.
- Operator commands without a DB: list numbers (safe), template report/registration (irreversible), test send (one
  **paid** message).

### 3.7 Push — Firebase Cloud Messaging

- FCM HTTP v1 directly (`golang.org/x/oauth2/google` + one POST), not the Admin SDK (a heavy dependency for one
  endpoint). Timeout 15 s; one call per device.
- Credentials = the whole service account JSON in SSM (filled from a file); the project id is read from the service
  account (prevents project A's credentials from being paired with project B's id). Kill switch `PUSH_ENABLED`.
- The push "address" = the **user**, not a token: tokens are read at send time (reminders wait for weeks; a snapshotted
  token has most likely rotated). ≥1 device receives → `SENT`; all tokens dead → permanent; any transient failure →
  retryable; payload rejected → permanent **without** touching the tokens.
- The FCM code is read before the HTTP status (`UNREGISTERED` arrives as a 404). Tokens are deactivated on
  `UNREGISTERED`, `INVALID_ARGUMENT` on the token, `SENDER_ID_MISMATCH` — outside the transaction; a failure = log, then
  swallow.
- **The Android notification channel name and the sound file are a contract with the app** (Android 8+ channel settings
  are frozen once created; changing one side = silent notifications with no error).

### 3.8 In-app inbox

Inbox = an ordinary channel whose adapter writes `user_notifications` rows (scheduling, cancellation, and skips come for
free); `ON CONFLICT (notification_uuid, recipient) DO NOTHING`; `created_at` truncated to milliseconds; keyset cursor
`(created_at, randid)`; unread count from a partial index `WHERE read_at IS NULL`; reads from the primary.

### 3.9 Kill switches — summary

| Env state | Registered sender | EXPAND result |
|---|---|---|
| Channel off | "disabled" sender | `SKIPPED/CHANNEL_DISABLED`, no recipient query, no cost |
| Channel on, audience paused | audience wrapper | that audience `SKIPPED/CHANNEL_DISABLED` |
| Channel on, configuration complete | real adapter | `PENDING` or `SKIPPED/NO_ADDRESS` |
| Channel on, configuration incomplete | — | **worker fails at boot** |

A channel declared in the catalog **always** has a registered sender (the disabled version when the switch is off).
Turning a channel off/on = one env change + apply, no deploy.

### 3.10 Admin emails and alerts

Internal admin notifications go through the ordinary outbox (audience `ADMIN`, one row per admin, the actor is not
notified, a switch per admin per type) — **except** error tracker alerts, which are sent **directly to SES** so they
still go out when Postgres is the one in trouble. **The alert path must not depend on the system it watches.**

---

## 4. Search (Typesense)

### 4.1 Architecture

- Postgres = source of truth; Typesense only **finds ids**. The query asks for `IncludeFields: "id"`, then the full rows
  are hydrated from SQL (`WHERE uuid IN (…)`) and **re-sorted** by relevance. The search path's response is identical to
  the non-search path's.
- **MUST** re-apply the owner scope/filters in the SQL hydration; rows still in the index but already gone are dropped
  from the page. Typesense `filter_by` is **not** a security boundary — but it **MUST** still be sent with the owner
  filter.
- Visibility through **separate collections**, not filters: an "all" collection (owner-scoped, requires auth) vs an
  "active" collection (public) — inactive entities cannot leak to the public by construction. The admin collection is not
  owner-scoped; access to it is protected by the admin guard, and its documents hold no references to personal documents.
- **(improvement)** escape `filter_by` values (Typesense backticks) or validate them strictly before assembling the
  filter — never assemble it by plain string concatenation.
- **(improvement)** decide explicitly per endpoint what happens when Typesense is down: degrade to a bounded `ILIKE` or a
  clear 503.

### 4.2 Schemas & collections

- Collection schemas **in code**; fields optional except the required ones; `created_at` int64 **unix ms** as the
  `DefaultSortingField`; the `uuid` field repeated in the document; facets for scoping (`user_uuid`, `role`, status);
  `TokenSeparators` `@ . - _ +`; phone numbers stored in two spellings (`+62…` and `08…`).
- `Ensure*Collection` is idempotent at API **and** worker startup ("already exists" = success); new fields are added via
  a schema PATCH (must be optional), tolerating concurrent schema changes (re-read + retry every 500 ms, max 30 times). A
  failed ensure in the worker is non-fatal (the outbox holds the events).
- Client `typesense-go/v3`, `WithConnectionTimeout(5s)`, `TYPESENSE_PROTOCOL/HOST/PORT/API_KEY`.

### 4.3 Indexer

- Every write to an indexed entity enqueues `(entity_type, entity_uuid, 'UPSERT'|'DELETE')` in the same tx; the
  `search-indexer` worker does 100 rows / 10 s; document `id = uuid` → idempotent upsert; entity missing → delete the
  document and treat it as done; deactivation → delete from the public collection; max 10 attempts, then `FAILED`.
- **MUST** never let the worker mark a type it does not know as done (incident: backfill rows of a new type were lost).
- Filling the index for existing data = an SQL enqueue backfill ([02-database.md](02-database.md) §5), run **after** the
  worker that knows its type is live, and rerun after a migration that adds document fields.

### 4.4 Production & local

- Production: one private EC2 instance, Typesense in Docker, data on a separate encrypted EBS volume, SG only from ECS,
  `TYPESENSE_HOST` derived by Terraform, the API key is one Terraform variable for the server **and** SSM
  ([08-aws-infrastructure.md](08-aws-infrastructure.md) §4.5).
- **MUST** pin one Typesense version, the same in production and locally (never e.g. 27.1 in production and 30.2 locally).
- Local: one container per session, bind `127.0.0.1`, dummy API key. **MUST NOT** use production Typesense from local.

---

## 5. Third-party integrations

### 5.1 General pattern

- **MUST**, for every integration: a client with its own timeout; retryable/permanent error classification in one place;
  unknown error = retryable + the body logged, truncated; credentials checked when the client is created (refuse to build
  without an API key).
- Optional integration = an `…OrNil` constructor: without configuration, HTTP paths degrade (a clear 503/400), the worker
  does not start and logs loudly, money-moving commands refuse.
- **MUST** allow base-URL overrides to a stand-in **only** in `ENVIRONMENT=local`, rejected at start in any other
  environment — for **every** base URL that receives credentials, without exception.
- **E2E fakes** (`scripts/e2e/fake*`, a separate Go module, started only when `E2E_FAKE_<X>_PORT` is set, bind
  `127.0.0.1`):
  - the scenario is encoded in the authorization code (`fake:<sub>:<email>[:norefresh|:noscope]`) → no setup;
  - every access token expires immediately → the refresh path is exercised on every call;
  - a `/_fake/*` control plane for tests: revoke, force 401, inject events, read call counters;
  - the logs fake implements only `FilterLogEvents` and deliberately ignores the filter pattern (tests prove the parser
    rejects non-errors);
  - an in-memory, path-style S3 fake without auth that also serves GETs like a CDN;
  - DynamoDB Local + a command that creates the local tables (rejects non-local endpoints).
- **Webhook sink** for new integrations: a small server behind a tunnel that stores the body **byte for byte** + the
  headers + the verification result, and can forward to a local server and answer a chosen status to observe the
  provider's retries. **MUST NOT** re-encode JSON before HMAC verification.

### 5.2 OAuth (Google, Zoom, etc.)

- `state` = 32 random bytes in base64url in Redis `<provider>_link_state:<state>` → account uuid, TTL 10 minutes,
  namespaced per provider, `GETDEL` (single use), must belong to the calling account, checked **before** anything is sent
  to the provider (without state, a link carrying the attacker's code attaches the attacker's account to the victim's
  account). Staged rollout: first count the requests without state (metric), then make it required.
- Consent with offline access + forced approval (always yields a refresh token); the redirect URI is registered exactly
  in the provider console.
- OAuth tokens are stored in the DB (integrations table, unique per (platform, sub) and per (account, platform)).
  **(improvement)** encrypt refresh tokens in the application (AES-GCM, key from a secret) instead of storing them as
  plaintext JSONB.
- **MUST** refresh tokens under a **row lock** (`SELECT … FOR UPDATE`): two concurrent refreshes use the same refresh
  token and the provider rejects the second with an `invalid_grant` that cannot be told apart from an account that is
  gone. The new token is stored before it is used; pin `AuthStyleInHeader`.
- **MUST** treat a dead token as a state, not a 500: set `reconnect_required_at` (compare-and-set, written outside the
  caller's transaction), operations answer **409 + the account that must be reconnected**, the worker sends a
  notification **once per mark**.
- **MUST** verify deauthorize/data-deletion webhooks before reading them (HMAC over the raw body, `hmac.Equal`, timestamp
  ≤ 5 minutes, empty secret → 503, failure to delete → 5xx so the provider retries).
- Releasing a new secret: fill SSM **before** the `app_secret_keys` change reaches `main`.

### 5.3 The payment gateway as a separate library

- All money paths live in a **separate Go repo**, pinned by tag: a gateway client (pure HTTP) + an **insert-only
  double-entry ledger** (balance = sum of entries) + **its own SQL migrations** + **its own DB pool** in the host
  application (e.g. 2 connections). The library reads no env besides the gateway configuration; the host provides the
  `*sql.DB`.
- **Money = integers**: whole units for the domain, minor units (`…Minor`, int64) for gateway amounts with decimals;
  conversion through functions that **error** when precision would be lost; no floats. Float noise from the gateway
  (`6908.139999999999`) is read as the nearest minor unit; a real third decimal is rejected.
- Gateway webhooks: HMAC **before** reading any field, over the raw body; the endpoint string exactly matches the
  registered one; duplicates = normal traffic (a no-op when the state has already moved past).
- **Webhook = doorbell**: correctness does not depend on the webhook arriving — the settlement worker asks the gateway
  directly for the status of every open invoice (daily and by age).
- Outgoing transfers are idempotent on the gateway side (deterministic reference). When the gateway's idempotency TTL is
  unknown, replays are **manual**, through a `--commit` command.
- **Sandbox by default**: only the exact value `true` in `…_PRODUCTION` points to production; an unknown value = error.
  All env values are trimmed (a newline from a secret mount breaks the HMAC).
- Egress through a NAT with a fixed EIP (`prevent_destroy`), registered in the gateway's IP allowlist (rejections show up
  as business codes, easy to misdiagnose).
- The platform account at the gateway is created **once per environment, by hand**.

### 5.4 The server calling paid APIs / fetching third-party URLs

- The server API key is separate from the browser key, restricted to the APIs in use and to the **NAT IP**; minimal
  field mask; short timeout, not retried on the request path (failure → estimate); results cached in Redis (e.g. 24
  hours). Prices charged to users are stored in Postgres.
- Server-side fetches of URLs from input/imports: host allowlist, `https` only, a size limit (e.g. 2 MB), no redirects to
  other hosts, spaced retries at most 5 times.

---

## 6. Object storage from the worker side

The full R2 rules (buckets, client, presign, naming, deletion) are in [09-cloudflare.md](09-cloudflare.md) §4.
Worker-specific:

- Derived objects (OG cards) are **content-addressed** (key = hash(design version + input)), uploaded with
  `Cache-Control: public, max-age=31536000, immutable`; a new design = bump the version constant → new key → deploy →
  requeue the jobs (requeue **after** the deploy, otherwise the old worker treats the jobs as "unchanged").
- The public page answers with the card URL only when the stored key = the key for the **current** input; until it is
  rendered, answer empty and the client falls back.
- Old derived objects are deleted after the job points at the new key (best-effort).
