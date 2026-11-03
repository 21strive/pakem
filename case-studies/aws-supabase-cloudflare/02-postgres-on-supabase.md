# Case study 02 — Postgres on Supabase

An illustration, not part of the standard: how the [case study](README.md) deployment met the connection rules of
[02-database.md](../../docs/02-database.md) §6–§7 with Supabase's managed Postgres and its pooler, Supavisor, reached from
an IPv4-only AWS VPC.

---

## 1. What ran

- PostgreSQL 17.6 on Supabase **Micro** compute: `max_connections` 60, ±23 backends when quiet.
- Supavisor pooler: **Pool Size 15**, **Max Client Connections 200**.
- Production migrations took 0.1–0.4 s per file.
- Read and write pools point at the same endpoint (no read replica yet).

## 2. Reaching it from an IPv4-only VPC

- Supabase's **direct-connection host only has an AAAA record**; the ECS VPC is pure IPv4 →
  `connect: cannot assign requested address`, and the API and the worker crash-loop (the connections are opened before
  the mode branch).
- **MUST** use the regional **pooler host** (it has an A record) with the username **`postgres.<project-ref>`** (the
  pooler routes on the ref). Host and username change **together, through Terraform**, never in the console.

## 3. Two endpoints, two jobs

| Endpoint | Mode | Used by |
|---|---|---|
| `<pooler-host>:6543` | transaction | the application (API, worker, one-off command tasks) — always with `POSTGRES_BINARY_PARAMETERS=true` |
| `<pooler-host>:5432` | session | manual work: psql, migrations, `pg_dump`, `CREATE INDEX CONCURRENTLY`, backfills |

The rules for each mode (what is forbidden on the transaction path, why manual work never goes through it) are in
[02](../../docs/02-database.md) §6.1 and §6.5.

## 4. Production env

| Variable | Production value | Why |
|---|---|---|
| `POSTGRES_{WRITE,READ}_HOST` | the regional pooler host | A record (§2) |
| `POSTGRES_{WRITE,READ}_PORT` | `6543` | transaction mode |
| `POSTGRES_{WRITE,READ}_USERNAME` | `postgres.<project-ref>` | the pooler routes on the ref |
| `POSTGRES_WRITE_MAX_OPEN_CONNS` / `POSTGRES_READ_MAX_OPEN_CONNS` | `10` / `10` | §5 |
| `LEDGER_DB_MAX_OPEN_CONNS` | `2` | §5 |
| `POSTGRES_BINARY_PARAMETERS` | `"true"` | required on `:6543` |
| `POSTGRES_SSLMODE` | `"require"` | §7 |
| `HTTP_IDLE_TIMEOUT` | default `120s` | longer than the ALB's 60 s idle timeout |

In `prod.tfvars` ([templates/prod.tfvars.example](templates/prod.tfvars.example)):

```hcl
  # ---- Postgres (Supabase, outside the stack) ----
  # This VPC is IPv4-only: use the POOLER hostname (it has an A record), not the direct host (AAAA only).
  # The pooler USERNAME starts with the project ref (the pooler uses it for routing).
  # 6543 = transaction pooler, which MUST go together with POSTGRES_BINARY_PARAMETERS = "true".
  # Migrations, psql, pg_dump, CREATE INDEX CONCURRENTLY still go through 5432 (session).
  POSTGRES_WRITE_HOST        = "<pooler-host>"
  POSTGRES_WRITE_PORT        = "6543"
  POSTGRES_WRITE_USERNAME    = "<user>.<project-ref>"
```

## 5. Pool sizes

The formula is [02](../../docs/02-database.md) §6.4. With this deployment's numbers:

- N = 2 × `api_max_capacity` (200% deploy) + worker (+ one command task) = 2 × 4 + 1 = **9** processes.
- **Transaction mode** (`:6543`): N × C ≤ M, where M = Max Client Connections per Supavisor pool (idle connections
  count) = 200 → C ≤ 22 → **10 + 10 + 2** (9 × 22 = 198). The 201st client is rejected with `EMAXCONN`.
- **Session mode** (`:5432`) pins one server slot per client connection: N × C ≤ Pool Size (15) — it **does not fit**
  more than one API task. Incident (October 13–18): the application still ran on the session pooler → 244×
  `EMAXCONNSESSION`, 500s during page-load bursts. The fix was the transaction endpoint with binary parameters (§6) and
  pools sized from env.
- **Server limit:** 2 × (Pool Size + 1) + other connections ≤ `max_connections` (60) → Pool Size stays at 15.
- Beyond Supavisor's `pool_checkout_timeout` the client is dropped (`driver: bad connection`); before that, queueing
  shows up as latency, not errors.
- The formula and its values are written as comments next to the pool settings in `prod.tfvars`, and recomputed when the
  compute size, Max Client Connections, or `api_max_capacity` change.

## 6. Binary parameters on Supavisor

Why the transaction pooler needs `binary_parameters` is [02](../../docs/02-database.md) §6.5. The release on this
deployment:

1. **Phase 1:** `POSTGRES_BINARY_PARAMETERS=true` on `:5432` only — the driver change shipped separately from the pooler
   change.
2. **Phase 2:** port `6543` **together** with the new pools (10 / 10 / 2); watched for 0 `EMAXCONN`, 0 driver errors,
   0 5xx.
3. **Rollback:** the port back to `5432`. `:6543` is never used without binary parameters.

Validation without staging: a local Supavisor with exactly the production env + an e2e burst test. Local evidence before
the fix: Supavisor 2,562/6,000 requests failed without binary parameters, 0 with them.

## 7. TLS

- `POSTGRES_SSLMODE = "require"` (encrypted, certificate not checked).
- For `verify-full`: the Supabase CA is not in the system trust store → ship the CA file in the image (it is public) and
  set `POSTGRES_SSLROOTCERT=<path>`; the mode switches to `verify-full` automatically.

## 8. Dumps and manual work

- Against production: only `pg_dump` and verification `SELECT`s, through the **session pooler `:5432`**.
- `pg_dump` with the same major version as the server (17 here), even when the machine's default client is newer.
- **Manual work through `:6543` poisons the application's pool connections** (local test: a
  `set_config('search_path', '', false)` from a dump landed on a pooled server connection → 28/400 application queries
  failed). Recovery: terminate that user's pooler server connections through `:5432`:
  ```sql
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE usename = current_user AND datname = current_database()
    AND backend_type = 'client backend' AND pid <> pg_backend_pid();
  ```
- A migration's psql was once rejected with `EMAXCONNSESSION`: run one short psql at a time, and keep the application on
  `:6543`.

## 9. What to monitor (Supavisor)

| Log pattern | Meaning |
|---|---|
| `EMAXCONNSESSION` | the 16th client in session mode (Pool Size 15) |
| `EMAXCONN … limit: M` | N × C > M in transaction mode |
| `driver: bad connection` | Supavisor dropped the client (checkout timeout) |
| `connection attempt N of 10 failed` | the pooler rejected connections at start, e.g. while old and new tasks overlapped in a deploy |
