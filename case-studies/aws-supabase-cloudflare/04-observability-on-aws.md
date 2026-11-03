# Case study 04 — Logs, error tracker, and dashboards on AWS

An illustration, not part of the standard: how the [case study](README.md) deployment met
[06-observability.md](../../docs/06-observability.md) with CloudWatch Logs, DynamoDB, and SES — no observability agent
and no error-tracking SaaS.

---

## 1. Logs: CloudWatch Logs

- Container stdout → the ECS `awslogs` driver → log groups `/ecs/<prefix>/api` and `/ecs/<prefix>/worker`, **30-day
  retention** (Terraform). No additional agent.
- Behind Cloudflare the real client IP for access lines is the `CF-Connecting-IP` header (or Fiber's `ProxyHeader` + a
  trusted-proxy check); otherwise the IP column holds the load balancer's address.
- Logged webhook bodies are nested JSON, so Logs Insights can read their fields.

## 2. The error tracker on CloudWatch + DynamoDB + SES

The design is [06](../../docs/06-observability.md) §4. On AWS:

```
api/worker → slog JSON + stderr → CloudWatch Logs
                                      │ FilterLogEvents every minute
                                      ▼
                         worker error-tracker ──► DynamoDB on-demand (groups, recipients, checkpoint)
                                      │                    ▲
                                      ▼                    │ endpoint /admin/errors…
                               email alert via SES   internal dashboard (Errors page)
```

- The CloudWatch **filter pattern** `?"\"level\":\"ERROR\"" ?"panic: " ?"fatal error: "` only narrows the set; the
  tracker parses every line again ([06](../../docs/06-observability.md) §4.2).
- **Count once without a lock:** per (slice, group) one DynamoDB `UpdateItem` with
  `ConditionExpression: attribute_not_exists(last_bucket) OR last_bucket < :bucket` (`ADD count`, `if_not_exists` for
  first_seen/status); the checkpoint is advanced on the condition that it still holds the old value.
- **Table** `<prefix>-error-tracker`: `PAY_PER_REQUEST`, `pk` + `sk`, `deletion_protection_enabled = true` +
  `prevent_destroy` (it holds the recipient list and the statuses admins set). Items `GROUP/<id>`,
  `RECIPIENT/<lowercase email>`, `STATE/checkpoint`; times in unix ms. Cost at this deployment's volume:
  ±$0.03–0.07/month.
- Alerts go **directly to SES**, not through the notification outbox: the alert path does not depend on Postgres.
- The admin error detail links to the CloudWatch console for ±1 minute around the sample.
- **IAM** (task role, narrow): `dynamodb:GetItem/PutItem/UpdateItem/DeleteItem/Query` on one table,
  `logs:FilterLogEvents` on the two log groups (ARN and `ARN:*`), `ses:SendEmail`.
- **Env:** `ERROR_TRACKER_ENABLED` (default false; instant rollback), `ERROR_TRACKER_TABLE`, `ERROR_TRACKER_REGION`,
  `ERROR_TRACKER_LOG_GROUPS` (all three **derived by Terraform**), `ERROR_TRACKER_DASHBOARD_URL`,
  `…_POLL_INTERVAL/_BUCKET/_SETTLE/_BACKFILL` (1m/1m/2m/168h; e2e 1s/2s/2s/1m), `…_DYNAMODB_ENDPOINT/_LOGS_ENDPOINT`
  (local only; rejected outside `ENVIRONMENT=local`).
- **E2E:** a fake CloudWatch Logs that implements only `FilterLogEvents` (and deliberately ignores the filter pattern, so
  tests prove the parser rejects non-errors) + DynamoDB Local + a command that creates the local table (it rejects
  non-local endpoints).
- It went live on 27 October 2026 and on its first day found old errors nobody had known about.

## 3. Latency & tracing with Logs Insights

- Use **Logs Insights** (`aws logs start-query` / `get-query-results`; 30 days in seconds). `filter-log-events` over 7
  days can take more than 2 minutes.
- Latency from Fiber access lines:
  ```
  fields @timestamp, @message
  | parse @message /\| (?<status>\d{3}) \|\s+(?<lat>[0-9.]+)(?<unit>[^ ]+) \| (?<ip>[^ ]+) \| (?<method>[A-Z]+) \| (?<path>[^ ]+) \|/
  | filter ispresent(status)
  | stats count(*) as n, pct(lat, 50) as p50, pct(lat, 95) as p95, max(lat) as worst by unit, method
  ```
  (the µs/ms/s units are converted outside the query; paths contain UUIDs → aggregate per route pattern outside the
  query).
- All ERRORs / one `error_id` from a user report / one request:
  ```
  fields @timestamp, msg, error, error_id, trace_id, operation_name, source.function
  | filter level = "ERROR"            # or: error_id = "ERR_…"  /  trace_id = "<uuid>"
  | sort @timestamp desc
  ```
- Logged webhook bodies: `filter @message like /"msg":"<Provider>\w+ (body|refused)"/`.
- A complement without parsing: the ALB `TargetResponseTime` p50/p95/p99 widget on the dashboard.

## 4. Metrics

The recommendation of [06](../../docs/06-observability.md) §5 on AWS: **CloudWatch Embedded Metric Format** (`_aws` JSON
lines on the same stdout, no agent/SDK) or metric filters on the log group, behind the `RecordXxx` wrapper.

## 5. Dashboard & alarms

- One CloudWatch dashboard in Terraform: ALB (requests, application vs ALB 5xx, 4xx, `TargetResponseTime` p50/p95/p99,
  healthy/unhealthy hosts), ECS per service (CPU, memory, running vs desired tasks), cluster & EC2 hosts. Agentless
  sources: `AWS/ApplicationELB`, `AWS/ECS`, `AWS/EC2`, `ECS/ContainerInsights` (Container Insights enabled). Free tier:
  3 dashboards × 50 metrics — count before adding widgets.
- **(improvement)** minimum alarms: `RunningTaskCount < 1` for the API and worker services + rising ALB 5xx → SNS email.
