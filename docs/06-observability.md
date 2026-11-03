# 06 — Observability: logs, traces, error tracker, metrics, latency

Observability is built from **structured logs to stdout** collected by the platform's log store, plus **our own error
tracker** (log store → a small store outside the main database → email) that replaces Sentry for the backend, a dashboard
from the infrastructure code, and saved log queries for latency & tracing. No additional observability agent or SaaS.
Which log store, key-value store, and email provider fill those roles is the project's decision; the
[case study](../case-studies/aws-supabase-cloudflare/04-observability-on-aws.md) shows one set.

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Logging

- **MUST** use `log/slog` JSON to **stdout**, `AddSource: true` (fields `source.function/file/line`), one global logger
  (`helper.SetLogger` + `slog.SetDefault`) installed in `main.init()` before anything else — all three modes (API,
  worker, command) are covered.
- Container stdout → the platform's log driver → one log group/stream per service (API, worker), **30-day retention**
  set by the infrastructure code. No additional agent.
- HTTP access lines = Fiber's `logger` middleware: `HH:MM:SS | <status> | <latency> | <ip> | <METHOD> | <path> | <error>`.
  Panics recovered by `recover` (with stack trace) go to stderr as `panic: …`.
- **(improvement)** access lines include `trace_id` (`${locals:trace_id}`) and the real client IP (behind an edge proxy:
  the client-IP header the edge sets, or `ProxyHeader` + a trusted proxy check) — otherwise access lines can be joined to
  ERROR lines only by time+path, and the IP column holds the load balancer's IP.
- Request milestones: a controller may write INFO "started"/"done" with `trace_id` + the operation name to reconstruct
  the request's journey.
- Levels: `Debug` on the base handler; ERROR for server faults, WARN for 4xx and expected failures.

## 2. Errors, `error_id`, `trace_id`

- `TraceMiddleware`: a UUID per request in `c.Locals("trace_id")` + the `X-Trace-ID` header (exposed through CORS) —
  clients can report it.
- Errors are built with `helper.NewErrorLog(err, Kind, DiagCtx{OperationName, UserUUID, …, Extra})`, which captures the
  caller's PC (the `source` field points at the originating usecase/repository). For server faults:
  `error_id = "ERR_" + 16 Crockford base32 characters` + `function/filename/line`.
- **One response funnel** (`responses.SendError/SendResponse`) logs the `ErrorLog` with `trace_id`, `error_id`,
  `error_kind`, `status_code`; ERROR for ≥ 500, WARN for 4xx; `msg` = the client message, the cause in the `error` field.
  On a 5xx the client receives only `"Internal server error"` + `error_id` ([03-api-design.md](03-api-design.md) §1).
- DB driver text (table/constraint names) goes only to the log. DB timeouts automatically become 503.
- **MUST NOT** put passwords, PINs, or tokens in `DiagCtx.Extra`.
- **(improvement)** `trace_id` flows into every outbox `Enqueue` (a `trace_id` column that is
  almost never filled is useless) — so a message that failed to send can be traced back to the request it came from.

## 3. Sensitive data in logs

Full rules: [03-api-design.md](03-api-design.md) §6.9. Additions for webhook logs (standardized after an incident in which
a settlement webhook was rejected three times with a log that only said "Invalid notification"):

- webhooks **without** personal data (totals, date windows, references) → the body of **every** verified delivery at
  INFO;
- webhooks **with** personal data (payments, payouts) → the body only when **rejected**, at ERROR, with the values under
  personal keys masked (`name`, `email`, `phone`, `mobile`, `msisdn`, `address`, `account_number`, `va_number`, `card`,
  `nik`, `npwp`, `birth`, `title`, `description`, `remark`, `note` — a key that **contains** one of these parts is masked
  together with its contents);
- a body that is not JSON and would need masking → not logged; limit 64 KB; the body is logged as nested JSON (the log
  store's query language can read its fields); the ERROR carries the parser's error text (the error tracker group names
  the field that changed);
- provider error bodies are logged **truncated** (512 bytes).

## 4. Error tracker (Sentry replacement for the backend)

**User decision (21 October 2026):** an error list + email alerts without Sentry's cost; a worker reads the logs
periodically, no LLM; one record per error type (count + last occurrence); recipients managed from the internal
dashboard; **no load on the main infra** → a small key-value store billed per request, not Postgres. On its first day in
production it found old errors nobody had ever known about — that is exactly where the tool's value lies.

### 4.1 Architecture

```
api/worker → slog JSON + stderr → log store
                                      │ read new lines every minute
                                      ▼
                         worker error-tracker ──► key-value store (groups, recipients, checkpoint)
                                      │                    ▲
                                      ▼                    │ endpoint /admin/errors…
              email alert, sent directly through    internal dashboard (Errors page)
              the email provider
```

It keeps running when Postgres has problems (a full-pooler incident is exactly the kind that must raise an alert);
Postgres is read only for the list of admin recipients, and if that read fails, alerts still go to the extra recipients.

### 4.2 Lines that are counted

- The log store's filter (for `"level":"ERROR"`, `panic: `, `fatal error: `) only narrows the set; each line is parsed
  again: JSON `level=ERROR` (text = the `error` field, or `msg` when absent; location = `source.function`), `panic: …`
  (PANIC), `fatal error: …` (FATAL).
- **Not** counted: WARN/INFO, `| 500 |` access lines (a 500 through `SendResponse` already has an ERROR line), stack
  lines.

### 4.3 Grouping

- Key = sha256(kind + the first 200 characters of the normalized text), 24 hex. One error logged in many places = **one**
  group (the places are stored in the `functions` set; the full-pooler incident logged from 18 functions). Generic texts
  are split per function. **Line numbers are never** part of the key (they shift with every deploy).
- Normalization: times → `<time>`, UUIDs → `<uuid>`, `ERR_…` → `<error_id>`, emails → `<email>`, IPs → `<ip>`, hex ≥ 12
  with digits → `<hex>`, decimals & numbers ≥ 4 digits → `<n>`; 1–3-digit numbers are left alone (HTTP status, pool
  size).

### 4.4 Count once without a lock

- Time is cut into `ERROR_TRACKER_BUCKET` slices (1 minute); a slice is read once it is `ERROR_TRACKER_SETTLE` old
  (2 minutes, so late lines have arrived); one pass runs from the checkpoint to the last ready slice, max 360 slices
  (6 hours); falling behind → the next pass after 1 s.
- Per (slice, group) one **conditional update**: add the slice's count only if the group's `last_bucket` is missing or
  older than this slice (set first_seen/status only when absent); the checkpoint is advanced on the condition that it
  still holds the old value. Any store with conditional writes works. The first pass goes back `ERROR_TRACKER_BACKFILL`
  (7 days). **Two processes are safe.**

### 4.5 The store

One table `<prefix>-error-tracker` in a key-value store billed per request, keyed `pk` + `sk`, with deletion protection
(it holds the recipient list & the statuses admins set):

| Item | Contents |
|---|---|
| `GROUP/<id>` | kind, function, file, line, functions (set), message, error_kind, status_code, services (set), count, first/last_seen_at, last_bucket, status, resolved_at, last_alert_at, sample ≤ 2 KB + log group/stream |
| `RECIPIENT/<lowercase email>` | extra recipient |
| `STATE/checkpoint` | next_bucket, updated_at |

Times = unix ms. Cost at a small SaaS's volume: cents per month.

### 4.6 Status & alerts

- OPEN / RESOLVED / MUTED (still counted, never emailed). A RESOLVED group that occurs again **after** `resolved_at` goes
  back to OPEN.
- Email: a new group (NEW), a resolved group that comes back (BACK, always), a spike ≥ 30 lines per slice (max 1 per group
  per hour); slices > 1 hour old (backfill/catch-up) are counted but not emailed; one email per pass, all recipients in
  `To`; failed emails are held in memory (max 50) for the next pass; extra recipients max 20 + every admin who has not
  turned off "Error alerts".
- Alerts are sent **directly through the email provider**, not through the notification outbox (the alert path does not
  depend on Postgres).

### 4.7 API, permissions, env

- Admin API (404 while the switch is off): `GET/PATCH /admin/errors[/{id}]` (the detail includes a link to the log
  store's console for ±1 minute), `GET/POST/DELETE /admin/error-alert-recipients`, `POST …/test`.
- The application identity (narrow): item operations on one table, reading the two log groups, sending email
  ([08-infrastructure.md](08-infrastructure.md) §4.6).
- Env: `ERROR_TRACKER_ENABLED` (default false; instant rollback), the table, region, and log group names (**derived by the
  infrastructure code**), `ERROR_TRACKER_DASHBOARD_URL`, `…_POLL_INTERVAL/_BUCKET/_SETTLE/_BACKFILL`
  (1m/1m/2m/168h; e2e 1s/2s/2s/1m), and endpoint overrides for the store and the log store (local only; rejected outside
  `ENVIRONMENT=local`).
- E2E: a fake log store + a local copy of the key-value store + a command that creates the local table
  ([07-testing-and-e2e.md](07-testing-and-e2e.md)).

### 4.8 Known limitations

A dead worker cannot report itself (the dashboard shows `last_checked_at`; see the alarms in §7); not covered: web/mobile
crashes, full stacks for ERROR lines, breadcrumbs, release tracking.

## 5. Metrics

- Convention to keep: **one wrapper file** (`app/utils/metrics.go`) with a named function per business event
  (`RecordBookingCreated(paymentMethod, meetingType)`), grouped per domain with comment banners; dotted metric names
  (`booking.created`, `auth.login.failed`, `notification.sent`); dimensions in attributes, not in the name; no metric
  strings scattered through business code; a no-op meter fallback in tests/CLI.
- **Sentry:** the error tracker replaces Sentry for backend errors. Keeping a Sentry SDK only for metrics means that
  emptying `SENTRY_DSN` silently turns every metric into a no-op.
- **Recommendation for new projects (open decision):** do not install Sentry in the backend; errors = the error tracker
  §4; metrics = **metric lines on the same stdout** that the log platform turns into metrics (no agent/SDK), or metric
  filters on the log group. Keep the `RecordXxx` wrapper shape so the metrics backend can be swapped without touching
  business code.

## 6. Latency & tracing (saved log queries)

- Use the log store's **query engine** for anything over more than a few hours; scanning raw lines over days is slow
  (over 7 days it can take minutes). Keep the queries below in the project's runbook, written in its log store's
  language (the case study has them in its log store's query language).
- **Latency** from Fiber access lines: parse `| <status> | <latency><unit> | <ip> | <METHOD> | <path> |`, then count and
  take p50/p95/max per method (convert the µs/ms/s units outside the query; paths contain UUIDs → aggregate per route
  pattern outside the query).
- **All ERRORs / one `error_id` from a user report / one request:** filter on `level = "ERROR"`, `error_id = "ERR_…"`, or
  `trace_id = "<uuid>"`; show `msg`, `error`, `error_id`, `trace_id`, `operation_name`, `source.function`, newest first.
- **Logged webhook bodies:** the lines whose `msg` is `<Provider>… body` or `<Provider>… refused`.
- A complement without parsing: the load balancer's response-time percentiles (p50/p95/p99) on the dashboard.

## 7. Dashboard & alarms

- One dashboard from the infrastructure code: the load balancer (requests, application vs load-balancer 5xx, 4xx,
  response time p50/p95/p99, healthy/unhealthy hosts), each service (CPU, memory, running vs desired instances), and the
  hosts/capacity. Use the platform's built-in metrics (no agent), and check the free-tier limits before adding widgets.
- **(improvement)** minimum alarms: running instances < 1 for the API and worker services + rising load-balancer 5xx →
  email (a worker that failed 146 times once went unnoticed until the circuit breaker was installed).
- Workers that guard business invariants emit an ERROR when an invariant is violated, so it lands in the error tracker
  ([05-workers-and-integrations.md](05-workers-and-integrations.md) §1.2).

## 8. What to watch after a deploy

- The build line (`revision` = the new SHA), no new ERROR/panic (compare with the **list of known noise**), pool/pooler
  log patterns ([02-database.md](02-database.md) §6.9), cache logs (`redifu: this build holds the cache lease`,
  [04-caching.md](04-caching.md) §9), and the Errors page on the internal dashboard.
