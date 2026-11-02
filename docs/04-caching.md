# 04 — Caching (redifu) and Redis rules

How the backend caches reads: each piece of data is stored once and many views refer to it;
the database records every change; a per-owner drain applies the changes to Redis with consistency guarantees; reads go
through a decorator that answers identically to SQL; generations + a lease make deploys and rollbacks free of manual
steps.

Markers: **MUST**, **MUST NOT**, **SHOULD**.

---

## 0. One-screen summary

```
 WRITE (request, worker, webhook, library, psql)                READ (GET …)
   │  no write code knows the cache exists                         │  decorator <entity>_cached_repository.go
   ▼                                                               ▼
 watched table ──trigger redifu_capture (AFTER, per row)           Store.Serve(owner, tables…)
   │   1 outbox row per changed row, IN THE WRITER'S TRANSACTION   │  Enabled? (REDIFU_READS, outbox exists, all tables
   ▼                                                               │  have triggers, Redis not paused, this build
 redifu_outbox (owner_uuid, table_name, row_key, op, old_row) ◀────┤  holds the lease)
   │                                                               │  1× EXISTS on the owner's queue (per read scope)
   ├─ background drain every 1 s (every API + worker process)      │  exists → DrainOwner first; failed/locked → SQL
   ▼                                                               │  none → read Redis; cold → Seed (owner lock)
 DrainOwner: try-advisory-xact-lock('redifu:'||owner), REPEATABLE  │  anything fails → the SQL repository answers
   READ, DELETE … RETURNING ≤500, per-table handlers reload the current rows through the same tx,
   Redis writes are recorded → WATCH {redifu:lease}:build → MULTI/EXEC → only then COMMIT Postgres
```

1. **Postgres is the only source of truth.** Redis holds only a rebuildable cache, short-lived state, or a buffer that
   loses at most one worker pass (§1).
2. **Singleton data layer:** every row is stored once as a `Base` entity (key = uuid). Indexes contain only uuids.
   Derived data = satellite, non-uuid lookup = handle, expensive computation = computed record (§2).
3. **The write path never touches Redis.** The database records changes through a trigger into an outbox (§3).
4. **Reads go through a decorator** on top of the SQL repository; its answer is identical to SQL; every failure falls
   back to SQL. A read that starts after a write commits always sees that write, from any process (§4.8, §6).
5. **Generations replace versions in key names**; the lease ensures only the newest build uses the cache; the epoch
   guards rollbacks and flushes (§5).
6. **Day-to-day operations need no special steps:** the `REDIFU_READS` switch, `command redifu-purge`, automatic
   deploys and rollbacks (§9).

### 0.1 Key numbers

| Item | Value |
|---|---|
| TTL of a `Base` entity (row, satellite, handle) | 7 days, extended on every read (`GETEX`, including through relations/`GetMany`) and on every write |
| TTL of an index + its markers | 2 days (`ListTTL`), renewed by seed, `SetExpiration`, `Extend` |
| Computed record | short, no touch-on-read (example: search results 5 minutes, marketplace 60 s, slot page 5 minutes) |
| Drain batch | 500 rows per transaction; a full batch is repeated immediately |
| Background drain | `REDIFU_DRAIN_INTERVAL` (default 1 s; forced > 0) |
| Owners per `DrainAll` pass | ≤ 200, oldest row first; owners in backoff are skipped |
| Stuck queue | ERROR when the oldest row is > 1 minute old (checked at most once per minute) |
| Read pause after a Redis failure | 5 s per process |
| Owner backoff after a failed drain | 5 s |
| Recheck of which tables have triggers | once per minute (no restart) |
| Wait for a primary pool connection | 0 when the pool looks full, at most 1 s; WARN ≤ 1×/minute |
| Seed/drain transaction limits | `statement_timeout` 15 s, `idle_in_transaction_session_timeout` 30 s (tx-local) |
| Cross-owner view lock | `pg_advisory_xact_lock` blocking, `lock_timeout` 5 s |
| Lease `:alive` / lease check | TTL 30 s / at most once per 250 ms per process |
| Cache Redis client | Dial/Read/Write/Pool timeout 1 s, `MaxRetries` 1 |
| Feed | head seed of n+1 rows; top-up ≥ 50 rows; at most 20 top-ups per read, more → SQL |
| Buckets | at most 13 UTC months per read, more → SQL |
| Purge | `SCAN` COUNT 500, `UNLINK` per key in a pipeline |
| Relation depth | 4 levels |
| Key parameter | non-empty, ≤ 512 bytes, no `{}`/control characters; user-supplied names as handles ≤ 200, no `:` `{` `}` |
| Generation | ≤ 128 bytes; value stored as `<gen>@<epoch>\x1f<json>`; Shape = `"s"` + 16 hex |
| Score | int64 ≤ 2^53; `created_at` in microseconds |

---

## 1. Redis rules: cache or short-lived state

Applies to **every** use of Redis, not only redifu (user decision, 19 October 2026).

- **MUST** treat Postgres as the only source of truth. Redis never becomes a stateful database. Allowed:
  1. a cache that can be rebuilt from Postgres or an external source;
  2. short-lived state with a short TTL that, when lost, only resets a limit or makes the user repeat one
     step (rate limit, OAuth `state`);
  3. a buffer that a worker copies to Postgres every pass, so at most one pass is lost.
- **MUST NOT** keep data that exists only in Redis and feeds permanent data.
- **Test before adding a key:** imagine Redis gets `FLUSHALL`ed right now. Once everything has recovered, is any number
  in Postgres (or any email, or any bill) wrong, or has any stopped increasing correctly? If so, store the data in
  Postgres first. **MUST** also account for **per-key eviction**: any key with a TTL can be evicted on its own when
  memory is full (`volatile-*`), and keys without a TTL can be evicted under `allkeys-*`.
- **MUST NOT** use Redis lists or `SETNX` for queues or locks. **Queues live in Postgres** (outboxes:
  `redifu_outbox`, `notification_outbox`, `search_index_outbox`, …) and **locks = Postgres advisory locks, `_xact_`
  variant**.
- **MUST** record every new key in its feature document: format, TTL, what is lost if Redis is flushed, and the
  behavior when Redis fails (fail-open/fail-closed).
- **SHOULD** use a **signed token** instead of Redis for short-lived state that can be made stateless. Example: a
  15-minute price lock = `base64url(JSON claims) "." base64url(HMAC-SHA256)` — nothing is stored, nothing needs to be
  cleaned up.
- **MUST NOT** put a version segment in any key name (`…:v1:…`) — outside redifu too (§5.1).
- **MUST NOT** store credentials in Redis: password hashes, login/refresh tokens, money-equivalent codes (buyers'
  voucher codes). Incident: an old write-only cache copied `password_hash` and tokens to Redis Cloud. Guarded by an e2e
  test that scans every Redis value (§8.3).
- Required Redis: **≥ 6.2** (`GETEX`), **single node** (the drain fence uses `WATCH` on one connection; Redis
  Cluster needs a different design). The design **must survive per-key eviction** (dangling detection, `ErrNotSeeded`,
  lost computed records are recomputed, a TTL on every key).

---

## 2. Cache data model

### 2.1 Principles

- **MUST** store every cached row **once** as a `Base` entity (one key per uuid). Indexes (`Sorted`, `Timeline`) store
  only uuids. Detail views, lists, public pages, and admin read the same entity. One write is enough for every view; no
  purge needed.
- **MUST NOT** copy another entity's fields into a cache item. Incident: service list items copied `CategoryName`;
  renaming a category needed a purge, the purge was forgotten, and the old name showed for up to 12 hours.
- **MUST NOT** purge an index because an entity's content changed — `Base.Set` is enough. An index is dropped only when:
  a read finds a member whose entity is gone (dangling), a read finds an index of another generation (`ErrNotSeeded`),
  or a mass change goes through `command redifu-purge`.
- **MUST** use the cache for **displaying**, not for **deciding**. Decisions still read the database under a lock:
  slot availability and time validation when creating a booking, the balance check for withdrawals, voucher check &
  redeem (quota/stock under a row lock), webhook idempotency. A stale slot at worst produces a 409, never a double
  booking.

### 2.2 Key types

| Type | Contents | Example key | Generation | TTL | Written by |
|---|---|---|---|---|---|
| **Row entity** | one row from one canonical SELECT, stored as DB columns | `service:<uuid>`, `booking:<uuid>`, `user:<uuid>` | `Shape(model, SQL)` | 7 days + GETEX | drain (Set/Del), seed (Set), Detail |
| **Satellite** | derived data per parent (output of Go code over several reads) | `service_terms:<service uuid>`, `booking_parts:<booking uuid>`, `wallet_balance:<owner>` | build | 7 days + GETEX | drain via `batch.Later` (once per batch), seed |
| **Handle** | pointer from a non-uuid key to a uuid | `user_handle:<username>`, `service_uri:<owner>/<uri>` | build | 7 days | drain (delete the old name, write the new one), seed on miss |
| **Index** | sorted set of uuids + markers | List `{service:list:<owner>}`, Feed `{booking:feed:<owner>:<tab>}`, Buckets `{booking:month:<owner>:<YYYY-MM>}`, global Sorted `{admin:users:<filter>}` | build | 2 days | seed, drain (`Add`/`Remove`) |
| **Computed record** | the answer of an expensive computation | `slot_page:<owner>\|<sha1>`, `booking_search:<owner>\|<gen>\|<hash>` | build | minutes, no touch | read path after computing |
| **Generation data** | "data changed" marker | `slot_epoch:<owner>` (Shape), `booking_search_gen:<owner>` (`INCR` counter) | Shape / none | 24 hours / 7 days | drain |
| **Lease** | the build that holds the cache | `{redifu:lease}:build` (no TTL), `{redifu:lease}:alive` (30 s) | — | — | every process (§5.5) |

Index markers: `{K}:blankpage` (confirmed empty), `{K}:firstpage`, `{K}:lastpage` (the index holds the end of the
data), `{K}:gen` (generation + epoch). Index keys sit inside a `{…}` hash tag so that one Lua script touches the set and
its markers together. Item keys do not use a hash tag.

### 2.3 Modeling rules

- **Transaction records = facts, not references.** Bookings, tax lines, invoices, and wallet transactions copy the
  service/client data as it was when the transaction happened. That copy stays in its entity and **MUST NOT** be
  `Relate`d to the source entity. Views that really do use current data map it at read time (e.g. the service color in
  the calendar).
- **Derived data = satellite** keyed by its parent's uuid, rewritten whole every time one of its source rows changes
  (service payment terms, booking payment totals, client statistics, wallet balance, latest KYC status).
- **One-to-many = one satellite per parent** (e.g. `booking_parts` holds one booking's payment terms, charges,
  vouchers, tax copies, team, resources, cashier summary). A per-parent index only when that list is shown on its own
  (`booking:by_session:<owner>:<session>`). redifu deliberately has no `RelateMany` (child indexes may not be seeded
  yet, staleness spreads, unbounded lists).
- **Values that depend on time or on the caller are computed at read time**, not stored: discount/event/voucher
  "running today" status, deviations that have not passed yet (in the owner's zone), past slots & lead time,
  per-member filters, presigned URLs.
- **Non-uuid lookups use a handle.** A handle is only a signpost: an answer is given only if the target still matches,
  like a `WHERE` in SQL (the account that still has that name, the service still at that address). A stale handle is
  reloaded, not followed.
- **"No row" stubs**: a relation to a uuid that has no row (default thumbnail, deleted upload) is stored as a `missing`
  stub with a special prefix — without the stub, every read seeds again. The stub is part of the `Shape`.

### 2.4 Identity and key names

- **MUST** key entities by **uuid**: `GetRandId()` returns `UUID`. All foreign keys and API parameters use uuids, so
  relations need no extra join. Deliberate exception: entities whose old cursor contract uses randid are keyed by
  randid so that the `created_at|randid` cursor stays the same.
- **MUST** name only the data's identity in a key format, **with no version segment**: `<entity>:%s`,
  `<entity>:list:%s`, `<entity>:feed:%s:%s`. One `%s` = one key segment (no `:`). Compound parameters are joined with
  `|` (`slot_page:<owner>|<sha1>`) or `/` (`service_uri:<owner>/<uri>`). That way purge can tell `voucher:%s` apart
  from `voucher:check:…`.
- **MUST NOT** use a user-supplied name as a key if it contains `:`, `{`, `}`, control characters, or is > 200 bytes —
  read such names from SQL (`redifuHandleUsable`). Purge must be able to find every cache key.
- Global lists (no owner) use the parameter `"all"` with the queue owner `''` (redifu rejects empty parameters).
- redifu rejects formats that contain `{`/`}` (it adds the hash tag itself) and any `%` other than `%s`; `Base` accepts
  only one `%s`.

### 2.5 Entity shape in Go

```go
type serviceEntity struct {
    *models.Service                   // the same model sqlx scans into
    Score     int64                   `json:"-"` // score for the next index write
    category  *serviceCategoryEntity  `json:"-"` // relation: filled at read time, never stored
    terms     *serviceTermsEntity     `json:"-"` // satellite
    owner     *userEntity             `json:"-"`
}
func (e *serviceEntity) GetRandId() string            { return e.UUID } // key = uuid
func (e *serviceEntity) SetScore(score int64)         { e.Score = score }
func (e *serviceEntity) MarshalJSON() ([]byte, error) { return redifucache.Encode(e.Service) }
func (e *serviceEntity) UnmarshalJSON(data []byte) error {
    e.Service = &models.Service{}
    return redifucache.Decode(data, e.Service)
}
// redifu RawCodec: store/read without encoding/json around it
func (e *serviceEntity) MarshalRedis() ([]byte, error)    { return e.MarshalJSON() }
func (e *serviceEntity) UnmarshalRedis(data []byte) error { return e.UnmarshalJSON(data) }
```

- Satellites and handles do not embed `*redifu.Record`; they implement `redifu.Blueprint` with no-op methods, and
  `GetRandId()` returns their key.
- **MUST** tag relation fields `json:"-"` (redifu rejects a relation without that tag: `ErrRelationNotTransient`).
  Without the tag, writing back a fetched item "bakes" a copy of the related entity into the parent's key — the
  singleton is broken for good.
- **MUST** register relations on the `Base` (`base.AddRelation(...)`), not on an index, so that they apply to `Get`,
  `GetMany`, and every index, resolved per page with one round trip per level (at most 4). A relation whose key has
  expired yields `nil`; the decorator then loads it under the owner lock (`complete`) or falls back to SQL.
- Domain models embed `*redifu.Record` (`uuid`, `randid`, `created_at`, `updated_at`); constructors call
  `InitRecord`. **MUST NOT** call `InitRecord` for rows read from the DB (a new randid orphans the index).

### 2.6 Codec: an entity is stored as its DB columns

- **MUST** encode entities by their **`db` tags**, not their `json` tags (the `json` tag is the API shape: some fields
  are `json:"-"`, some are renamed). What comes out of Redis must be exactly what sqlx scans. Embedded structs are
  flattened the way sqlx does it; exported fields without a tag use the lowercase name; `db:"-"` is skipped; for
  duplicate column names, the shallowest field wins.
- **MUST** store times with the instant, the offset, **and the zone name** (`"<RFC3339Nano>|<zone>"`): lib/pq gives a
  `timestamptz` the session zone `"UTC"` and a `timestamp` the zone `+00:00` without a name; plain JSON loses that
  difference and `reflect.DeepEqual` in the parity test fails.
- `Decode` uses a single-pass scanner (falling back to encoding/json for unknown tokens); columns that are no longer in
  the model are skipped. Measured: decoding one entity 50 → 7 µs; a list of 35 entities 3.6 → ±1.5 ms.
- `Project(dst, src, columns...)` copies only the columns the SQL query selects; the other columns stay zero, just as
  sqlx leaves them. **MUST** project the entity onto the column list of the SQL query it replaces, on every read from
  the cache.
- JSON columns that must come back byte for byte are stored as separate raw JSON (the column codec compacts
  `json.RawMessage`).

### 2.7 Scores and ordering

- **MUST** set the score explicitly in the `Score int64` field (`SetSortingReference("Score")`) right before ingest —
  one entity can sit in several indexes with different scores. The redifu default (`created_at` ms) is **not** used.
- Creation-time scores are in **microseconds**: Go `t.UnixMicro()`; SQL
  `floor(extract(epoch FROM created_at) * 1000000)::bigint`. Cursor to timestamp in SQL:
  `(TIMESTAMP '1970-01-01 00:00:00' + $n::bigint * INTERVAL '1 microsecond')`.
- Calendar indexes (`Buckets`) use scores in **seconds** (`start_time`), split per UTC month.
- Numeric columns (`display_order`) are used directly. Non-numeric orderings (names) use the **rank from SQL** as the
  score (`ORDER BY lower(name), uuid`); the drain re-requests the owner's whole ranking when a name/the set changes
  (O(N); ±0.7 s for 3,000 rows in miniredis).
- **MUST**: tiebreak = uuid byte by byte = SQL `uuid COLLATE "C"` (redifu's Lua compares members byte by byte,
  independent of locale). Add this tiebreak to the reference SQL's `ORDER BY`: `ORDER BY s.display_order, s.uuid
  COLLATE "C"`.
- **MUST NOT** use scores > 2^53 (`ErrScoreOutOfRange`).

---

## 3. Write path: trigger → outbox

### 3.1 Rules

- **MUST**: the write path never writes to Redis, and a write never fails because of Redis. The incidents behind this
  rule (an old cache written from requests): a failed `Set` failed sign-ups/profile edits while Redis had problems; ±20
  Redis round trips per insert/update ran **before commit** under an advisory lock while the pooler had only 15 slots;
  wrong keys across tenants.
- **MUST** let the database itself record changes: the row trigger `redifu_capture` (AFTER INSERT/UPDATE/DELETE)
  writes one `redifu_outbox` row **in the writer's transaction**. Writers outside requests (workers, webhooks, libraries
  that write their own tables, `psql` backfills) are covered automatically. This design was chosen over "write Redis
  after commit" because in local simulations the after-commit approach stayed stale forever on: a crash after commit,
  write races, writers outside the app, and Redis being down — while the outbox was correct in every case. **Final
  decision; do not reopen it.**
- **MUST** store only `row_key` and `old_row` in the outbox. The drain **always reloads** the current row from the DB
  and never trusts new contents from the outbox. `old_row` is used to know which indexes have held the row until now.

### 3.2 Core SQL (the first cache migration)

Copy [`templates/backend/sql/redifu_outbox.sql`](../templates/backend/sql/redifu_outbox.sql). It contains:

- the table `redifu_outbox (id bigserial PK, owner_uuid text NOT NULL DEFAULT '', table_name, row_key, op,
  old_row jsonb, created_at timestamptz DEFAULT clock_timestamp())` + index `(owner_uuid, id)`;
- `redifu_owner_of(spec, data)` — a row's owner: its own column, `''` (global), or `parent:<parent table>:<fk
  column>:<parent owner column>` (owner read from the parent row);
- `redifu_capture()` — the trigger: an UPDATE that changes nothing is **not recorded**; an UPDATE that moves the owner
  is recorded **for both owners**; `old_row` = the row's contents before the change (NULL for INSERT);
- `redifu_watch(table, key column, owner spec)` — reinstalls that table's one and only `redifu_capture` trigger
  (idempotent);
- `redifu_unwatch_all()` — removes every trigger (rollback to a binary without the cache).

Tables currently watched: `SELECT tgrelid::regclass FROM pg_trigger WHERE tgname = 'redifu_capture';`

### 3.3 Owner spec

| Spec form | Meaning | Example |
|---|---|---|
| `'<column>'` | owner = the value of that column in the row | `redifu_watch('services','uuid','user_uuid')` |
| `'uuid'` on the account table | the account is its own owner | `redifu_watch('users','uuid','uuid')` |
| `''` | global table, owner `''` | `redifu_watch('public_holidays','date','')` |
| `'parent:<parent>:<fk>:<owner column>'` | owner read from the parent row | `redifu_watch('booking_payments','uuid','parent:bookings:booking_uuid:user_uuid')` |
| key = parent column (junction) | `row_key` names the parent → the handler rebuilds the parent's satellite | `redifu_watch('booking_staff','booking_uuid','user_uuid')` |
| another outbox table as a signal | a search-index change bumps the owner's search generation | `redifu_watch('search_index_outbox','id','parent:bookings:entity_uuid:user_uuid')` |

Migration form for each later package:

```sql
BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT redifu_watch('bookings', 'uuid', 'user_uuid');
SELECT redifu_watch('booking_payments', 'uuid', 'parent:bookings:booking_uuid:user_uuid');
SELECT redifu_watch('booking_staff', 'booking_uuid', 'user_uuid');
COMMIT;
```

### 3.4 Cache migration rules

- **MUST**: a cache migration contains only `redifu_watch` calls, with no schema change to application tables; one
  transaction with `SET LOCAL lock_timeout = '5s'` (installing a trigger needs a table lock); idempotent.
- **MUST**: every migration that watches the same table uses **exactly the same** arguments (`redifu_watch` recreates
  that table's one and only trigger; the migration that runs last wins).
- **MUST** watch **every** table a view reads: relations, satellites, junctions, and every input table of a
  computation. `Store.Watches(tables...)` turns that view's cache off (reads go through SQL) as long as even one table
  has no trigger yet.
- **MUST** run the watch migration **before** the binary that reads the table. If the order is reversed, the view is
  read from SQL until the migration runs (the store rechecks the trigger list every minute, without a restart).
- **MUST NOT** watch a table the cache does not read (a trigger adds cost to every write).
- Child rows deleted along with their parent by `ON DELETE CASCADE` cannot find the parent → they are recorded with
  owner `''`. Handlers **MUST** ignore them (`if batch.Owner == "" { return nil }`); the parent's deletion is already
  recorded for its owner.
- Data migrations (`UPDATE`/`INSERT` in a migration or in `psql`) enqueue outbox rows automatically → the cache follows
  without a restart, flush, or deploy.
- `ALTER TABLE … ADD COLUMN` does **not** fire row triggers. A new entity shape is detected by `Shape` (§5.2), not by
  the outbox.
- Cost: every cache read pays one queue `EXISTS` per owner per call; bulk UPDATEs are ±3× slower because of the per-row
  trigger; a `parent:` spec runs one dynamic SELECT against the parent table per row. Triggers run in the writer's
  transaction, so an error in the trigger function (e.g. a renamed parent table) fails the application's write — test
  migrations that change triggered tables together with their watch migrations, and keep the trigger function as simple
  as in the template.

---

## 4. The `redifucache` engine

The engine lives in `app/redifucache/` (`store.go`, `codec.go`, `codec_fast.go`, `list.go`, `feed.go`, `buckets.go`,
`detail.go`, `scope.go`, `generation.go`, `lease.go`, `fence.go`, `purge.go`). For a new project see §12.

### 4.1 Public API

```go
// store.go
func NewStore(db *sqlx.DB /* primary */, rdb redis.UniversalClient, reads bool /* REDIFU_READS */) *Store
func (s *Store) Client() redis.UniversalClient
func (s *Store) DB() *sqlx.DB
func (s *Store) Query(ctx context.Context, fn func(q sqlx.QueryerContext) error) error // primary pool, bounded wait
func IsPoolBusy(err error) bool

type Handler interface {
    Tables() []string                                        // tables it follows
    Apply(batch *Batch, table string, changes []Change) error // changes of one table, in id order
}
func (s *Store) Register(h Handler) // several handlers may follow one table

type Change struct { ID int64; Owner, Table, Key, Op string; OldRow *string } // one redifu_outbox row
func (c Change) Old() Row                                                    // nil for INSERT
type Row map[string]json.RawMessage // .Str(col) .Int(col) .Bool(col) .Null(col) .Time(col)

type Batch struct { Ctx context.Context; Tx *sqlx.Tx; Owner string; Pipe redis.Pipeliner /* recorder */ }
func (b *Batch) Local(key string, init func() any) any   // batch-owned value (collect satellite keys across tables)
func (b *Batch) Later(key string, fn func() error)        // once per key, after all tables of the batch are applied
func (b *Batch) LockGlobal(name string) error             // cross-owner view lock (blocking, lock_timeout 5s)
func (b *Batch) AfterExec(fn func(context.Context) error) // after MULTI/EXEC

func (s *Store) Ready(ctx context.Context) bool  // outbox exists; refreshes the trigger list every minute
func (s *Store) Watches(tables ...string) bool
func (s *Store) RedisFailed(err error)           // 5 s read pause (redis.Nil is ignored)
func (s *Store) Enabled(ctx context.Context, tables ...string) bool
func (s *Store) Serve(ctx context.Context, owner string, tables ...string) bool // owner "*" = cross-owner
func (s *Store) ServeOwner(ctx context.Context, owner string, tables ...string) (ok, drained bool)
func (s *Store) ServeMany(ctx context.Context, owners []string, tables ...string) map[string]bool
func (s *Store) Seed(ctx context.Context, owner string, fn func(tx *sqlx.Tx, pipe redis.Pipeliner) error) (bool, error)
func (s *Store) SeedView(ctx context.Context, name string, tables []string, fn func(tx *sqlx.Tx, pipe redis.Pipeliner) error) (bool, error)
func (s *Store) DrainOwner(ctx context.Context, owner string) (bool, error)
func (s *Store) DrainAll(ctx context.Context) (int, error)
func (s *Store) Backlog(ctx context.Context) (int64, time.Duration, error)
func (s *Store) RunDrainLoop(ctx context.Context, interval time.Duration)

// generation.go
func BuildGeneration() string                 // buildinfo.Revision, or "bin-<16 hex>" binary fingerprint, or "dev"
func Shape(sample any, sql ...string) string  // row entity generation
func (s *Store) BuildGeneration() string
func (s *Store) Epoch() string
func (s *Store) Formats() []KeyFormat         // KeyFormat{Format string; Index bool; Generation string}
func NewBase[E redifu.Blueprint](store *Store, keyFormat string, ttl time.Duration, generation string) (*redifu.Base[E], error)
func NewSorted[E redifu.Blueprint](store *Store, base *redifu.Base[E], keyFormat string, ttl time.Duration) (*redifu.Sorted[E], error)
func NewTimeline[E redifu.Blueprint](store *Store, base *redifu.Base[E], keyFormat string, perPage int64, direction string, ttl time.Duration) (*redifu.Timeline[E], error)

// lease.go
func ObserveLease()     // called by main for "command" mode: never takes/renews the lease
func BuildOrder() int64 // buildinfo.Time (Unix seconds), or the binary mtime + WARN

// list.go — the whole list in one Sorted, filtered/sliced in Go
type Scored interface { redifu.Blueprint; SetScore(score int64) }
const ListTTL = 2 * 24 * time.Hour
const EntityTTL = 7 * 24 * time.Hour
func NewList[E Scored](store *Store, base *redifu.Base[E], keyFormat, dir string, tables []string,
    load func(ctx context.Context, tx *sqlx.Tx, params []string) ([]E, error),
    owner func(params []string) string) (*List[E], error)
func (l *List[E]) Read(ctx context.Context, params ...string) ([]E, bool)
func (l *List[E]) ReadServed(ctx context.Context, params ...string) ([]E, bool) // without another queue check
func (l *List[E]) ReadPage(ctx context.Context, start, stop int64, params ...string) ([]E, int64, bool)
func (l *List[E]) Count(ctx context.Context, params ...string) (int64, bool)     // ZCARD, no decode
func (l *List[E]) Fill / Add / Remove(ctx context.Context, pipe redis.Pipeliner, …) error
var ErrNotCached = errors.New("redifucache: not served from the cache")

// feed.go — Timeline with a position cursor and top-up from the tail
func NewFeed[E Scored](store *Store, base *redifu.Base[E], keyFormat string, perPage int64, direction string, tables []string,
    load func(ctx context.Context, tx *sqlx.Tx, params []string, after redifu.Cursor, limit int64) ([]E, error),
    owner func(params []string) string) (*Feed[E], error)
type FeedPage[E Scored] struct { Items []E; Next redifu.Cursor; HasMore bool }
func (f *Feed[E]) Read / ReadN / ReadServed(...) (*FeedPage[E], bool)
func EncodeCursor(cursor redifu.Cursor) string       // base64url("<score>:<member>"), "" = zero
func DecodeCursor(text string) (redifu.Cursor, error) // ErrBadCursor

// buckets.go — Sorted per (owner, UTC month), scores in seconds
const MaxBucketMonths = 13
func NewBuckets[E Scored](store *Store, base *redifu.Base[E], keyFormat string /* %s owner, %s YYYY-MM */, tables []string,
    load func(ctx context.Context, tx *sqlx.Tx, owner string, from, to int64) ([]E, error)) (*Buckets[E], error)
func (b *Buckets[E]) Read(ctx context.Context, owner string, from, to int64) ([]E, bool) // [from,to] inclusive
func (b *Buckets[E]) CountBetween(ctx context.Context, owner string, from, to int64) (int64, bool)

// detail.go — entity per key; the owner is known only after the entity is read
func NewDetail[E redifu.Blueprint](store *Store, base *redifu.Base[E], tables []string,
    owner func(E) string, load func(ctx context.Context, q sqlx.QueryerContext, keys []string) ([]E, error)) *Detail[E]
func (d *Detail[E]) Get(ctx context.Context, keys ...string) (map[string]E, bool) // keys not in the DB are absent from the map

// scope.go, codec.go, purge.go
func NewReadScope(ctx context.Context) context.Context
func Encode(model any) ([]byte, error); func Decode(data []byte, model any) error
func Project(dst, src any, columns ...string) error
func (s *Store) Purge(ctx context.Context, rdb redis.UniversalClient, dryRun bool) (PurgeReport, error)
```

### 4.2 `Enabled` and `Serve`

`Enabled(tables)` is true only when **all** of these hold: `REDIFU_READS`, Redis is not in its 5 s pause,
`redifu_outbox` exists, every table has a trigger, and this build holds the lease.

`ServeOwner(ctx, owner, tables)`:

1. `!Enabled` → read through SQL.
2. The read scope has already marked this owner → served without a query.
3. Regular owner: `SELECT EXISTS (SELECT 1 FROM redifu_outbox WHERE owner_uuid = $1)` through the primary pool. Error →
   SQL. No queue → served. Queue present: owner in backoff → SQL; otherwise `DrainOwner`, and served only if the drain
   finishes without an error.
4. Owner `"*"` (cross-owner view: admin, marketplace): only the owners that have rows in **that view's tables** are
   drained; an owner in backoff sends the read to SQL without retrying its drain.
5. If served, the owner is marked in the scope.

`ServeMany(owners, tables)`: one query `SELECT DISTINCT owner_uuid FROM redifu_outbox WHERE owner_uuid = ANY($1)`,
drains the owners that need it, and returns the set of owners that may be read from Redis (example: the unread counts of
all accounts of one login).

### 4.3 Drain algorithm (`DrainOwner` → `drainBatch`)

1. Take a primary pool connection: the pool looks full → `errPoolBusy` (treated like a busy lock); wait at most
   1 s.
2. `BEGIN ISOLATION LEVEL REPEATABLE READ`.
3. Lock + transaction limits in one round trip:
   ```sql
   SELECT pg_try_advisory_xact_lock(hashtextextended('redifu:' || $1, 0))
     FROM (SELECT set_config('statement_timeout', '15000', true),
                  set_config('idle_in_transaction_session_timeout', '30000', true)) AS limits
   ```
   Not locked → return `locked=false` (another drain/seed holds this owner; its queue is theirs to handle).
4. Take the queue:
   ```sql
   DELETE FROM redifu_outbox
    WHERE id IN (SELECT id FROM redifu_outbox WHERE owner_uuid = $1 ORDER BY id LIMIT $2)  -- $2 = 500
   RETURNING id, owner_uuid, table_name, row_key, op, old_row::text AS old_row
   ```
   SQLSTATE `40001` (this snapshot predates another drain's commit) → back off as for a busy lock. Empty → commit.
5. Sort by `id`, group by table (in order of first appearance), and run **every** handler of that table with
   `Batch{Tx, Owner, Pipe: recorder}`. Tables with no handler in this binary are skipped.
6. Run the `Later` steps in queue order (a `Later` may enqueue another `Later`).
7. Send the recorded Redis writes in **one `MULTI/EXEC` behind the lease fence** (§5.6), then `AfterExec`.
8. Lease lost (`errLeaseLost`, `errLeaseMissing`, `redis.TxFailedErr`) → rollback, `locked=false` (the queue stays for
   the holder). Redis write error → `RedisFailed` (5 s read pause), rollback. Handler error → rollback.
9. Postgres `COMMIT` (deletes the outbox rows), clear the owner's backoff status.
10. Repeat while the batch is full. On error: owner backoff 5 s + ERROR `redifu: drain failed`.

Consequence: Redis is written **before** the Postgres commit. If the commit fails, the outbox rows remain and are
applied again. **MUST** make every handler operation idempotent (Set/Del/ZADD/ZREM).

Rules for writing a handler:

- **MUST** take the unique keys per table together with each key's **first** change (`redifuChangeKeys`) — the
  `old_row` of the first change is the state Redis currently holds.
- **MUST** reload the current rows through `batch.Tx` with **the same canonical loader as the seed**. Present → `Set` +
  `Add` to its new indexes; gone → `Del`. The old indexes are computed from `old_row`: `Remove` if the old owner, type,
  or status differs. A changed score only needs another `Add` (ZADD updates it). Moving to another month bucket =
  `Remove` from the old month.
- **MUST** recompute satellites **once per batch** through `batch.Later("<satellite>:<key>", …)`; collect keys across
  tables with `batch.Local`.
- **MUST**: a cross-owner view's handler calls `batch.LockGlobal("<view name>")` before moving members; that view's seed
  uses `SeedView` with the same lock name.
- Handlers may write generation data (e.g. `INCR booking_search_gen:<owner>` + `EXPIRE`, a new slot epoch per batch).
  A handler may ignore changes that only touch a stamp column (`last_active_at`).

### 4.4 Seed algorithm (`Seed` / `SeedView`)

1. Take a connection (pool full → `false`: read through SQL).
2. `REPEATABLE READ` transaction, try-lock the owner (or the view name) with the same lock SQL. Busy → `false`.
3. **Seeding is refused while the queue is not empty**: an owner seed checks `EXISTS … WHERE owner_uuid = $1`;
   `SeedView` checks `… WHERE table_name = ANY($1)` (anyone's queue on that view's tables). Present → `false`; this
   read goes through SQL, and the next read applies the queue first.
4. `fn(tx, pipe)`: the loader reads through `tx` (the snapshot from the lock statement), then queues writes into
   `pipe = rdb.TxPipeline()`: `Base.Set` for every item (**`Set`, not `SetIfAbsent`** — the seed also heals stale
   keys), `IngestItem(seed=true)`, `MarkEmpty` or `HasData`, `SetExpiration`.
5. `pipe.Exec` (MULTI/EXEC); error → `RedisFailed`. Then `COMMIT`.

Seeds are **not** fenced by the lease (§5.6). Design reasons (code review): Redis reads a plain pipeline > ±16 KB in
chunks interleaved with other clients' commands → a reader can see a half-filled index as a complete list (hence one
`MULTI/EXEC`); a seed after the queue check can read a write that is still queued and then reverted → the entity is
left in the wrong index (hence REPEATABLE READ + refusing to seed while a queue exists).

### 4.5 Index blocks

**List** — an owner's whole list in one `Sorted`, filtered/sliced in Go. `SetSelfHeal(false)`.

- `Read`: `Serve`, then up to 2 attempts: needs a seed → seed → `Fetch(dir).ExecReport` → `ErrNotSeeded` → retry;
  `Count`. The answer is accepted only if `dangling == 0`, `len(items) == ZCARD`, and (`count > 0` or an empty marker
  exists). Otherwise `Purge` and retry. Two failures → SQL.
- `ReadPage(start, stop)`: only the entities of that page are decoded (`WithRankRange`); `start >= count` → an empty
  page with the total.
- `Count`: `ZCARD` without reading the members; zero without an empty marker = cold index → seed.
- `Add`/`Remove` from the drain: `AddItem` only inserts into an index that is **already seeded** (`ZCARD > 0`) and
  always deletes the `:blankpage` marker (a list confirmed empty is seeded again by the next read). `ErrNotIngested` is
  a normal result.

**Feed** — position cursor + top-up from the tail:

```
loop (max. 20 top-ups + 3 passes):
  count == 0 && !IsEmpty         → seedAfter(head, n+1)                ; cold index
  out = FetchFrom(after).WithLimit(n)
  out.Dangling() > 0             → Purge, retry
  !out.HasMore() && !ReachedEnd  → tail = Tail(); seedAfter(tail, max(n-len+1, 50)); retry
  return {Items, NextCursor, HasMore}
seedAfter(head):  UnmarkLastPage, IngestItem(seed=true) per item, MarkEmpty / MarkLastPage (if < limit), HasData, SetExpiration
seedAfter(tail):  Timeline.Extend(pipe, tail, items, len < limit)  ; rejected if the index no longer ends at tail
                                                                    ; or is not this generation → read again
```

- **MUST** top up from `Tail()`, not from the client's cursor (the cursor can lie beyond the tail after the index
  expires → a gap).
- **MUST** top up through `Extend`, not `IngestItem(seed=true)` (an index dropped between `Tail` and the top-up would
  become an index without a head).
- **MUST** give the feed loader exactly the same keyset as the index — score, then member byte by byte:
  ```sql
  WHERE (floor(extract(epoch FROM created_at) * 1000000)::bigint, uuid COLLATE "C") < ($score, $member)
  ORDER BY 1 DESC, uuid COLLATE "C" DESC LIMIT $limit
  ```
- One index serves every page size (`ReadN`; the client's `per_page` is capped before it gets in).
- Cursor for the client: `EncodeCursor` = base64url `"<score>:<member>"`; malformed → `ErrBadCursor` (400); negative
  score → 400, not a panic.

**Buckets** — a calendar per (owner, UTC month), scores in seconds:

- `Read(owner, from, to)`: ≤ 13 months. Per month: needs a seed → `SeedMonth` → `Fetch(Ascending).WithRange` →
  `ZCOUNT` of the range; mismatch → `Purge` that month and retry.
- `CountBetween` = `ZCOUNT` across months, only to decide between cache and SQL (e.g. a window with > 400 rows → SQL).
- An empty month is marked empty; the first write to that month drops the marker.

**Detail** — `GetMany(keys)` → `ServeOwner` for every owner of the entities it sees → if any owner was drained,
`GetMany` again. Missing keys: load from the DB (outside the lock) to learn the owner, then per owner `Serve` + `Seed`
(reload under the lock, `Set`), then read back through `Base` so that relations resolve. Keys that do not exist in the
DB do not appear in the map. **MUST** still answer not-found through the SQL path (same error message).

**Global Sorted (admin)** — one `Sorted` per filter, scored by `created_at` in µs, read per page with
`WithRankRange`; seeded through `SeedView("admin", …)`, the drain calls `LockGlobal("admin")`, reads use
`Serve(ctx, "*", tables...)`. (`redifu.Page` and `TimeSeries` are **not used**.)

### 4.6 Read scope

- **MUST** use one read scope per repository method call (`ctx := redifucache.NewReadScope(ctx)`): the handles,
  indexes, entities, and satellites in one answer pay only **one queue check per owner**. The `Serve` guarantee still
  holds because its first check happens after the call starts. **MUST NOT** keep a scope beyond its call.
- **SHOULD**: one view = one repository call (e.g. `GetByUserUUIDWithServices`, `ListOwnerLists`). Real example: five
  separate reads = 11 statements, one call = 7. Use `ReadServed`/`CountServed` after `Serve` for the same owner.
- New projects: the repository interface **accepts the request's `ctx`** and the scope wraps it (`NewReadScope(ctx)`),
  so the request's deadline applies too (never build the scope from `context.Background()`).

### 4.7 Failure matrix

| Event | Behavior |
|---|---|
| `REDIFU_READS=false` | all reads go through SQL; **the drain keeps running** and the lease is still claimed |
| `redifu_outbox` does not exist yet / table has no trigger yet | that view goes through SQL; rechecked every minute |
| Redis error in read/seed/drain | all reads of that process go through SQL for 5 s; the drain is rolled back, the queue stays |
| Primary pool full / wait > 1 s | read through SQL (read pool); seed/drain = busy lock; WARN ≤ 1×/minute |
| Owner lock held by another drain/seed | that read goes through SQL; the lock holder applies the queue |
| Handler error | rollback; owner backoff 5 s (that owner's reads go through SQL); ERROR; other owners keep running |
| Queue stuck > 1 minute | ERROR `redifu: outbox backlog is old` (once per minute) |
| This build does not hold the lease | all reads go through SQL; does not drain the queue |
| Takeover in the middle of a drain | `WATCH` aborts the `EXEC` → rollback, the queue stays for the holder |
| Member entity missing (evicted/other generation) | the read counts it as dangling → `Purge` + reseed; never truncates the list |
| Index belongs to another generation | redifu drops the index; `Sorted` read → `ErrNotSeeded` → reseed |
| Page/offset outside int64 | SQL, not a panic |
| Not-found | SQL answers (same message and kind) |

### 4.8 Consistency guarantees (must be preserved)

1. **Read-your-writes across processes.** A read that starts after a write commits always sees it, from any API,
   worker, or webhook — the owner's queue is applied first, or SQL answers the read.
2. **Atomic for readers.** One seed and one drain batch land whole in one `MULTI/EXEC`; an index is never half filled;
   an entity that moves between indexes is never absent from both.
3. **One snapshot.** The contents of Redis always equal the state named by the `old_row` of the first change in the
   queue.
4. **Per-owner serialization.** An owner's seed and drain never interleave; a cross-owner view has a global lock that
   its seed and drain take.
5. **Never a truncated list.** A missing member triggers a rebuild (redifu self-heal is turned off).
6. **Answer = SQL.** Every failing path falls back to the SQL repository.
7. **Build isolation.** Values/indexes of another generation = miss; only the build holding the lease serves the cache
   and drains the queue.

Staleness windows that exist by design: search result membership ≤ 5 minutes, marketplace ≤ 60 s (entity contents stay
current); a build that has just lost the lease can serve state for ≤ 250 ms (its writes are fenced immediately).

### 4.9 Background drain & pooler

- Every API process runs `go store.RunDrainLoop(ctx, interval)` (in `routes.NewHTTPRoute`), and the `redifu-drain`
  worker (part of the unnamed `worker`) runs the same loop. **MUST** force the interval > 0 in every caller
  (`time.NewTicker(0)` panics).
- `DrainAll` runs only when `Ready` and this build holds the lease.
- **MUST**: the engine uses only the `_xact_` advisory lock variants and `set_config(…, true)`/`SET LOCAL` inside
  transactions — safe on the transaction pooler (`:6543`), where session state and session locks leak to other clients.
- The store uses the **primary** pool (dbWrite) for queue checks, seeds, and drains: a lagging replica would write stale
  data to Redis until the TTL runs out.

---

## 5. Generations, lease, epoch

### 5.1 Why keys carry no version

The version segment (`booking:v3:%s`) was removed because: (1) a static global version number — bumping it turns the
whole cache cold; (2) unsafe during a rolling deploy — old tasks drain the same outbox into the old-version keys, the
new-version keys fall behind, and `GETEX` keeps them alive forever; (3) it did not protect what a version is supposed to
protect — `Decode` fills in zero for new columns without an error, `ADD COLUMN` fires no trigger, and frequently read
entities never expire.

**MUST NOT** put a version in a key name. **MUST** build every `Base` and index through `redifucache.NewBase`,
`NewSorted`, `NewTimeline`, `NewList`, `NewFeed`, or `NewBuckets`, which set the generation and register the key format
with the `Store`.

### 5.2 Two kinds of generation

| Layer | Generation | When it changes |
|---|---|---|
| Row entity (one row from one canonical SELECT) | `Shape(model{}, columns, FROM/JOIN, child queries…)` | struct/tag/type/column/JOIN/child query changes → that entity's values are reloaded; on other deploys it stays warm |
| Index, satellite, handle, computed record | build generation (image commit) | every deploy: seeded/recomputed once on first read |
| Data (`slot_epoch`, search counter) | driven by the data, through the drain | unaffected by deploys |

- `Shape` hashes the codec version + a recursive Go type description (field names, types, tags; types from outside the
  module that encode themselves are represented by their name; types of this module that encode themselves are
  described as well) + the SQL text with normalized whitespace → `"s" + hex(sha256[:8])`.
- **MUST** build the row entity loader from constants that also go into `Shape`:
  ```go
  const serviceEntityColumns = `s.uuid, s.randid, … , u.randid AS user_randid`
  const serviceEntityFrom    = `FROM services s INNER JOIN users u ON u.uuid = s.user_uuid`
  var serviceEntityShape     = redifucache.Shape(models.Service{}, serviceEntityColumns, serviceEntityFrom)
  ```
- **MUST** add a revision (`"rev 2"`) to the `Shape` arguments (or use the build generation) when the loader's
  **meaning** changes without the type/SQL changing: assembly done in Go inside the loader, list post-processing, the
  decision to store a `missing` stub, a changed `MarshalJSON`/`UnmarshalJSON`, a format that is deleted and later added
  back with the same shape.
- **MUST** use `store.BuildGeneration()` for satellites, handles, and computed records — their contents are the output
  of Go code, and no type fingerprint can see a change in their meaning (real example: a fix to the total-income
  calculation changed the contents of the balance satellite without changing its type).
- **MUST**: two `Base`s that share a key (e.g. `user:%s` for accounts and admin) use the same shape variable. One format
  with two generations is **rejected at start** (panic in the provider).
- Indexes use the build generation because the membership rules (WHERE) and the scores live in Go code. The cost is one
  reseed per list per deploy. The alternative "definition hash + manual `Rev`" was rejected: forgetting to bump `Rev` =
  a wrong list for up to 2 days.

### 5.3 Build stamp

`app/buildinfo/buildinfo.go`: `var Revision, Time string`, set through `-ldflags` from `GIT_SHA` and `BUILD_TIME`
(Dockerfile + `deploy.yml`, see [08-aws-infrastructure.md](08-aws-infrastructure.md) §5).

- Without `Revision`: build generation = binary fingerprint `"bin-<16 hex>"` + one WARN (two local builds do not share
  indexes).
- Without `BUILD_TIME`: build order = the binary's mtime + one WARN.
- Startup log: `<app>: build revision=… built_at=… mode=…` and `redifu: cache generation build=…`.

### 5.4 Generations in redifu (`SetGeneration`)

- `Base`: value = `<generation>\x1f<json>`. A value with no prefix or with another prefix = the key does not exist
  (`Get` → `ErrNotFound`, `GetMany` skips it, relation `nil`, `ExecReport` counts it as dangling). `SetIfAbsent`
  overwrites it.
- Index: the `{K}:gen` marker. A missing/different marker gets the index dropped by the first operation that finds it,
  **in the same command as that operation's work** (read = check script + read in one `MULTI/EXEC`;
  `AddItem`/`RemoveItem` = a guarded script that drops, then `ErrNotIngested`; seed writes = stamp script).
- A `Sorted` read on a foreign/cold index answers `ErrNotSeeded`, **not an empty list**.
- `SetGeneration` may be called while the cache is in use (the epoch mechanism depends on this).
- **MUST** run every seed of a generation-stamped index in one `MULTI/EXEC` (`TxPipeline`).

### 5.5 Lease: only the newest build uses the cache

The problem it closes: a drain applies **the rules of the build that runs it**. During a rolling deploy, the old tasks'
drain does not touch indexes/satellites newly added by the new build → the new build serves them stale until the TTL
runs out.

- Keys: `{redifu:lease}:build` = `"<build time>|<generation>|<epoch>"` (no TTL) and `{redifu:lease}:alive` (TTL 30 s,
  renewed by the holder).
- Claim (Lua script), at most once per 250 ms per process:
  - this build is the holder → renew `:alive`, epoch unchanged (also when all of its processes were down for a while and
    no other build came in);
  - lease empty (first time, Redis flushed) → take it with a **new epoch**;
  - this build is newer (larger `BUILD_TIME`; if equal, larger generation) → take it, **keep the epoch** (upgrade: the
    old build's drain maintained values of the same shape);
  - this build is older and the holder's `:alive` has expired → take it with a **new epoch** (rollback/crash-looping
    rollout);
  - otherwise → not the holder: reads go through SQL, the queue is not drained.
- Epoch = `strconv.FormatInt(time.Now().UnixNano(), 36)`; the generation of every cache = `<generation>@<epoch>`. A new
  epoch = the whole cache cold once, so a build that holds the lease again does not find its old state that nobody
  maintained.
- **MUST**: `command` processes call `redifucache.ObserveLease()` in `main`: they use the cache only if their build
  holds the lease, and **never** take/renew it (a command from a newer build does not kill the production cache).
- Logs: `redifu: this build holds the cache lease`, `redifu: cache epoch`,
  `another build holds the cache lease, this process reads SQL`.

### 5.6 Drain fence (`fence.go`)

- Handlers write into a **recording pipeline** (a go-redis client pointed at an unreachable address, with a hook that
  swallows the sends): no Redis connection is held while handler SQL or `LockGlobal` runs.
- `commitBatch`: `WATCH {redifu:lease}:build` → `GET` the lease; empty → claim again once; different from what this
  process last held → `errLeaseLost`; same → `TxPipelined` all recorded commands. The lease changes between the check
  and EXEC → `TxFailedErr`. Redis fails → 5 s read pause.
- **Single-node design** (WATCH + all keys of the batch on one connection). Redis Cluster needs a different design.

### 5.7 Deploy and rollback

| Situation | What happens | Ops steps |
|---|---|---|
| Regular deploy (same entity shape) | the new build takes the lease on its first request/tick (epoch unchanged); the old build reads SQL until its tasks stop; entities stay warm; indexes/satellites/computed records are reseeded once | none |
| Deploy that changes an entity's shape | old-shape values = miss, reloaded from SQL | none |
| Deploy that adds an index/satellite | the lease guarantees every change is applied with the new build's rules | none |
| Rollback between lease-aware builds, crash-looping rollout | the old build takes over with a new epoch (cache cold once) | none |
| Redis flushed | lease empty → new epoch → cache cold once | none |
| Rollback to a binary **without** the cache | nothing drains the queue | `SELECT redifu_unwatch_all(); TRUNCATE redifu_outbox;` then, **before** the cache is turned on again: `command redifu-purge` |

---

## 6. Read path: decorator

### 6.1 Rules

- **MUST** leave the SQL repository unchanged: it is the reference, the fallback, and the answer when
  `REDIFU_READS=false`. The cached version is a decorator that embeds the SQL interface and overrides only the cached
  read methods. Every write and every other read goes straight to SQL. The usecase does not know the cache exists
  (unless the API contract really does change, e.g. cursors).
- **MUST** return exactly what SQL returns: same struct, same columns (`Project` onto the SELECT columns), same order
  (tiebreak `uuid COLLATE "C"` on both sides), same empty vs nil, same errors and not-found (not-found is answered by
  the SQL path).
- **MUST**: the SQL path has the same contract as the cache path (cursors: SQL uses an identical keyset).
- **MUST** compute time-dependent values (`now()`, today, the owner's zone) at read time.
- **MUST**: every failing path → call the embedded SQL method with the same arguments. No error ever comes from the
  cache.
- **MUST**: repositories do not import `requests`/`responses` (architecture test) — decorators use type aliases
  declared in their SQL file.
- **MUST** compute pages through the bounds helper (`redifuPageBounds`): page < 1, `perPage` < 1, or an offset outside
  int64 → SQL.
- **MUST** keep free-form public parameters from creating new keys without bound; a computed record is stored only when
  its parameters are used as is.

### 6.2 Decorator skeleton

```go
type cachedServiceRepository struct {
    ServiceRepositoryInterface            // SQL: every write and every other read
    cache *redifuServiceCatalog
}

func NewCachedServiceRepository(sql ServiceRepositoryInterface, store *redifucache.Store, accounts *RedifuAccounts) (ServiceRepositoryInterface, error) {
    catalog, err := newRedifuServiceCatalog(store, accounts) // Base, relations, List, Detail, store.Register(handler)
    if err != nil {
        return nil, err
    }
    return &cachedServiceRepository{ServiceRepositoryInterface: sql, cache: catalog}, nil
}

func (r *cachedServiceRepository) GetServiceDetailForUser(request *serviceDetailRequest) (*models.Service, *helper.ErrorLog) {
    ctx := redifuReadScope()
    found, ok := r.cache.ByUUIDs(ctx, []string{request.ServiceUUID})
    service, exists := found[request.ServiceUUID]
    if !ok || !exists || service.owner == nil {
        return r.ServiceRepositoryInterface.GetServiceDetailForUser(request) // SQL answers, including not-found
    }
    projected, ok := projectService(service, serviceDetailColumns) // redifucache.Project onto the SQL SELECT columns
    if !ok {
        return r.ServiceRepositoryInterface.GetServiceDetailForUser(request)
    }
    projected.Username = service.owner.Username // the JOINed field is filled from the related entity
    return projected, nil
}
```

### 6.3 Wiring in the provider

```go
func (p *RepositoryProvider) cacheReads(dbWrite *sqlx.DB, client redis.UniversalClient) {
    if client == nil {
        return // no Redis: everything goes to SQL
    }
    store := redifucache.NewStore(dbWrite, redifuClient(client), config.Get().Redifu.Reads)
    slog.Info("redifu: cache generation", "build", store.BuildGeneration())
    must := func(err error) { if err != nil { panic(fmt.Sprintf("redifu cache: %v", err)) } } // only a key-format bug
    accounts, err := repositories.NewRedifuAccounts(store); must(err)
    service, err := repositories.NewCachedServiceRepository(p.Service, store, accounts); must(err)
    p.Service = service
    // … every decorator wraps its SQL provider field …
    p.Redifu = store
}

// cache-only Redis client: same server, short timeouts, one retry
func redifuClient(client redis.UniversalClient) redis.UniversalClient {
    base, ok := client.(*redis.Client)
    if !ok || base == nil {
        return client
    }
    options := *base.Options()
    options.DialTimeout, options.ReadTimeout, options.WriteTimeout, options.PoolTimeout = time.Second, time.Second, time.Second, time.Second
    options.MaxRetries = 1
    return redis.NewClient(&options)
}
```

- Every process (API, worker, command) calls `NewRepositoryProvider`, so all of them build the `Store` and register
  the handlers; any process that holds the lease can drain the queue.
- `command redifu-purge` uses the main Redis client (not `redifuClient`) for SCAN/UNLINK.
- Reads that do not go through a repository (e.g. an internal library that reads its own tables) are cached as an
  **optional usecase dependency** (`WithXReadCache`); the library path stays the reference and answers everything the
  cache cannot, including not-found. The library's tables are watched like any other table (owner through `parent:`),
  so the library's webhooks and workers need no hooks.

---

## 7. What gets cached

### 7.1 Criteria

- **User direction:** design from the singleton model and **cache by default**: lists, details, search results per
  search key, slots, notifications, wallet, admin, marketplace. "Volatile" is no reason to refuse caching (one key per
  entity handles it); derived data = satellite; time-dependent values are computed at read time.
- **Measured limit:** every cache read pays one queue `EXISTS`, so the cache **MUST** only go on reads that are more
  expensive than one indexed query: lists, joins, aggregates, N+1 groups, hot public pages, expensive computations.
- **Stays in SQL:**
  - single-row lookups by primary/unique key (`GetByUUID`, `GetByUsername`) — they cost the same as the queue check;
  - reads of **one** entity in a write flow (one booking's detail, preview, reminder);
  - small admin lists (one internal user, a few rows, 1–2 indexed queries); admin lists that grow with the user base
    (e.g. the account list) are cached;
  - light lists (id, name, flag), small details, aliases;
  - credentials and buyers' codes;
  - quota/stock read under a row lock, and every decision in §2.1;
  - things that need a limit: dated windows > 400 candidates, ranges > 13 months, deep scroll > 20 top-ups.
- **N+1 outside the cache is fixed in SQL**, not with the cache (example: the "mulai dari" ("starting from") price per
  card = 49 queries per profile visit → one `GetByUUIDs`).

### 7.2 Pattern map

| View need | Block | Example |
|---|---|---|
| Whole list per owner (≤ hundreds of items), filtered/sliced in Go | `List` | services, categories, add-ons, discounts, taxes, availability, team, clients, vouchers, bank accounts |
| Infinite scroll with a cursor | `Feed` | booking list per status tab, notification inbox, wallet history, payouts |
| Time range | `Buckets` per (owner, UTC month) | calendar, date filter, external calendar busy blocks |
| Page numbers (admin) | global `Sorted` + `WithRankRange` | admin account list |
| Count | `List.Count` (`ZCARD`) | unread notifications |
| Detail / search result hydration | `Detail.Get` | hydrating IDs from the search engine, service detail |
| Search results per key | short-TTL computed record + per-owner search generation | booking search (5 minutes), marketplace (60 s) |
| Expensive computation | computed record + per-owner epoch + "valid until" | public slot page |
| Global list | `List` with owner `''`, parameter `"all"` | default templates, public holidays |

Every project maintains an "Already cached" table (package, view/endpoint, entity/index) in its own
`docs/reference/platform/redifu.md`.

### 7.3 Acceptable limitations

O(N) re-ranking when a name changes; several queue checks per page when the scope is per repository call (not per
request); a large seed for a cold count can exceed the 1 s Redis timeout (falls back to SQL); the order of ties within
the same microsecond.

---

## 8. Testing the cache

### 8.1 Unit parity test (real Postgres + miniredis)

- **MUST** use a real Postgres with the full schema from the migrations (`REDIFU_TEST_DSN`, prepared by
  `scripts/e2e/local/db-reset.sh`) + `miniredis.RunT(t)`. Skip when the DSN is empty or the tables have no triggers yet.
- **MUST** have three counters:
  - a SQL repository wrapper that counts **fallbacks** (not-found answered by SQL is not counted) — without it, a cache
    that always falls back to SQL passes every parity check;
  - a `database/sql` connector that counts queue checks (`FROM redifu_outbox WHERE owner_uuid = $1`) and lock attempts;
  - a go-redis hook that counts `SET`s.
- Standard scenario (the `TestServiceCacheMatchesSQL` pattern): build data with direct SQL `INSERT`s (several owners,
  score ties, relations) → `all("cold")` → `all("warm")` with fallback = 0 → every kind of write through SQL, each
  followed by `all(...)` (rename a relation, reorder, deactivate, move to another category, change URI/username, change
  a satellite, delete a relation with an FK `SET NULL`) → `mr.FlushAll()` → `all(...)` with fallback = 0 (must seed,
  not SQL) → delete & move owner → outbox rows of the test owners = 0. The `all()` matrix: whole list, pages 1–4 ×
  `per_page` {1, 2, 5, 10, 100}, every filter, public vs owner, detail, hydration. Everything is compared with
  `reflect.DeepEqual`.
- Additional tests that **MUST** be copied: a warm read writes zero keys and takes zero locks; one queue check per owner
  per call; page number overflow → SQL; a name with `:` never becomes a key, and a stale handle is not followed.
- Engine tests (`app/redifucache/*_test.go`): flow (every write is followed, concurrent drains converge, a scope applies
  the queue once), fallback to SQL (owner locked, reads off, table without a trigger, Redis down and then recovered,
  pool busy), resilience (rebuild when a member is missing, seed+drain in one transaction, the feed keeps its end after
  the index expires, the seed waits for the queue, one snapshot), generations & lease (Shape sees value contents, one
  format with two generations is rejected, two builds with one shape share entities but not indexes, the lease keeps
  new indexes current, a takeover aborts the drain), purge & codec.

### 8.2 Guard tests

- `TestRedifuCachesTakeAGeneration`: scans the AST of every non-test `.go` file in `app/` except `redifucache/` and
  `mocks/`; direct `redifu.NewBase/NewSorted/NewTimeline/NewPage/NewTimeSeries/NewSortedSet` calls are rejected
  (explicit exceptions only for third-party API caches outside the Store).
- `TestRedifuKeyFormats`: no version segment `(^|:)v[0-9]+(:|$)`; every format has a generation; no curly braces; every
  index has the build generation; the formats on specific lists must be Shape or build.
- `TestArchitecture` (repositories do not import HTTP DTOs).

### 8.3 E2E parity test

- The server under test and its references share one DB and one Redis: `E2E_BASE_URL` (cache on),
  `E2E_REDIFU_SQL_URL` (the **same** binary with `REDIFU_READS=false`), optionally `E2E_REDIFU_MASTER_URL` (the binary
  from before the change), `E2E_REDIFU_SECOND_URL` (a second instance: write through A, read through B),
  `E2E_REDIS_ADDR` (flush).
- Modes per step: `parityWarm` (write → probe), `parityCold` (flush → write → probe), `parityFlushAfter`
  (write → flush → probe). Data is built through the public API.
- **Probe:** one GET to every server; the JSON is compared after dropping `trace_id`, `error_id`, and the `Ignore`
  paths; `Want` = the status the reference must answer (prevents scenarios that only compare 404s); `Eventual` only for
  the staleness windows that exist by design (retried every 3 s until the window runs out).
- **Walk:** paginated lists are walked to the end (page numbers and cursors); every page **and** the union of all items
  are compared.
- **Cache key test** (runs last): after signup, login, refresh, password reset, and a profile edit, scan **every** Redis
  value — no password hashes, JWTs, tokens, or forbidden key families may appear. Values are never printed.
- E2E generation test: index marker `<commit>@<epoch>`, entity value `s<16hex>@<epoch>\x1f`, the lease names this
  build; `redifu-purge --dry-run` deletes nothing; purge deletes every cache key and does not touch non-cache keys; two
  builds: the newer one holds the lease, and a write through either build is immediately readable on both.
- Reference results from a production rollout: 13 parity suites 298 PASS / 0 FAIL; production dump copy: 766 probes ×
  cold/warm = 1532 identical, 0 different; full master-vs-branch regression with an identical FAIL set.

### 8.4 Tests that need a real Redis

miniredis does not emulate every type (e.g. HyperLogLog is stored as its own type), so features such as
`PFMERGE`/HLL bytes **MUST** be tested on a real Redis (`REDIS_TEST_ADDR`, a separate DB per package).

---

## 9. Operations

- **Emergency switch `REDIFU_READS`** (default `true`; write exactly `true`/`false`). `false` and then redeploy: all
  reads go through SQL, the queue is **still** drained → Redis stays current, and the switch can be turned back on
  without a flush.
- **Health:**
  - `SELECT count(*), min(created_at) FROM redifu_outbox;` must be small and recent;
  - ERROR logs: `redifu: outbox backlog is old`, `redifu: drain failed`, `redifu: background drain failed`,
    `redifu: pending check failed`, `redifu: cannot refresh the watched tables`;
  - WARN logs: `redifu: redis failed, reads go to SQL for a while`, `redifu: the database pool is busy, cached reads go
    to SQL`, `another build holds the cache lease…`;
  - owners whose drain fails are read from SQL automatically until they recover.
- **Clearing the cache: `command redifu-purge [--dry-run]`** — one SCAN; keys that match a registered format are
  `UNLINK`ed; other keys are counted per prefix (`scanned N keys, deleted M, kept K` + one line per format). Safe while
  the application is running (the next read seeds). Does not take/renew the lease. Deliberately does **not** delete the
  search generation counters.
- **MUST NOT** use `FLUSHALL`/`FLUSHDB` to clear the cache — the same Redis holds rate limits, OAuth state, buffers, the
  lease, and paid API caches. With the §1 rules followed, `FLUSHALL` is **data-safe** but costly: cold cache + new
  epoch, rate limits reset, OAuth linking in progress has to be redone, buffers lose ≤ one pass.
- **Deploy & rollback:** no steps (§5.7), except a rollback to a binary without the cache.
- **New project bootstrap:** outbox + watch migrations → binary. Lease empty → the first process takes it with a new
  epoch. Nothing needs to be purged.

---

## 10. Redis outside redifu: implementation patterns

| Pattern | How | Redis failure |
|---|---|---|
| **Fixed-window rate limit** | key `…:<unix/period>`; `TxPipeline` `INCR` + `EXPIRE 2×period`, compare the `INCR` result with the limit (count **before** deciding, so concurrent requests do not all get through); "giving a count back" uses Lua `if EXISTS then DECR end` | **fail-open** (the limit only slows abuse down) unless stated otherwise |
| **Single-use state** (OAuth `state`) | `SET <provider>_link_state:<state> <value> EX 600`, taken with `GETDEL`; one prefix per provider | the user repeats the step |
| **Invalidating a computation through its key** | put every input that can change into the key (owner, settings version, price, service) + a per-owner version counter (`INCR` + `EXPIRE` longer than the value's lifetime) bumped by other events; for date-dependent computations, put the time zone and "today" into the key | miss → compute |
| **Computed record** | `redifucache.NewBase` + build generation + short TTL + `SetTouchOnRead(false)` (TTL counted from the time of computation) | miss → compute |
| **Paid third-party API cache** | long TTL (e.g. 24 hours); whatever is billed to users is still stored in Postgres | call the API again |
| **Analytics buffer (HyperLogLog)** | the API path only does `PFADD`/`HINCRBY`/`SADD` (no Postgres); a worker every 30 s per owner-day: `pg_try_advisory_xact_lock`, read the registers from Postgres, `PFMERGE` into the live key through a temporary key in the same slot, write the registers that changed (maps never shrink, numbers with `GREATEST`); registers are stored in JSONB as base64 (not `bytea`: binary parameters send `[]byte` as text); validate HLL bytes before sending them back to Redis; scripts through `EVAL` in a pipeline | events fail to be recorded; the loss is ≤ one pass |
| **Multi-key script** | all keys of one script in one slot (hash tag) so there is no `CROSSSLOT` if Redis is sharded | — |

Every project maintains a **Redis key inventory** (format, type, TTL, if lost, if Redis fails, source) in its platform
document. Example rows:

| Key | Type | TTL | If lost | Redis fails |
|---|---|---|---|---|
| `voucher:check:rejections:<username>:<unix/60>` | rate limit 30 NOT_FOUND/minute → 429 | 120 s | limit resets | fail-open |
| `google_link_state:<state>` | single-use OAuth state | 10 minutes | linking is redone | 500 on save |
| `stats:ov:<user>:<sha1>` | statistics answer cache (the key includes the zone & today) | 60 s | recomputed | miss |

---

## 11. Recipe: adding a cache for a new table/view

Generic example: table `widgets` owned by `user_uuid`, junction `widget_tags`, view "the owner's widget list ordered by
`sort`".

1. **Decide** (§7.1): more expensive than one indexed query? Who is the partition owner? Which tables are read
   (relations, junctions, computation inputs)? Any values that depend on time/the caller?
2. **Watch migration** (before the binary):
   ```sql
   BEGIN;
   SET LOCAL lock_timeout = '5s';
   SELECT redifu_watch('widgets', 'uuid', 'user_uuid');
   SELECT redifu_watch('widget_tags', 'widget_uuid', 'parent:widgets:widget_uuid:user_uuid');
   COMMIT;
   ```
   If the table is already watched by another migration: **exactly the same** arguments.
3. **Reference SQL:** the SQL repository's `ORDER BY` ends with `uuid COLLATE "C"`; for cursors, a SQL path with an
   identical keyset.
4. **Entity + canonical loader + Shape** (`widget_cache.go`):
   ```go
   const (
       widgetEntityKey = "widget:%s"
       widgetListKey   = "widget:list:%s"
   )
   const widgetEntityColumns = `w.uuid, w.randid, w.created_at, w.updated_at, w.user_uuid, w.name, w.sort`
   const widgetEntityFrom = `FROM widgets w`
   var widgetEntityShape = redifucache.Shape(models.Widget{}, widgetEntityColumns, widgetEntityFrom)
   var widgetTables = []string{"widgets", "widget_tags"} // every table of the view; all must have triggers

   type widgetEntity struct {
       *models.Widget
       Score int64 `json:"-"`
   }
   func (e *widgetEntity) GetRandId() string               { return e.UUID }
   func (e *widgetEntity) SetScore(score int64)            { e.Score = score }
   func (e *widgetEntity) MarshalJSON() ([]byte, error)    { return redifucache.Encode(e.Widget) }
   func (e *widgetEntity) UnmarshalJSON(b []byte) error    { e.Widget = &models.Widget{}; return redifucache.Decode(b, e.Widget) }
   func (e *widgetEntity) MarshalRedis() ([]byte, error)   { return e.MarshalJSON() }
   func (e *widgetEntity) UnmarshalRedis(b []byte) error   { return e.UnmarshalJSON(b) }

   func loadWidgets(ctx context.Context, q sqlx.QueryerContext, tail string, args ...any) ([]*widgetEntity, error) {
       var rows []*models.Widget
       if err := sqlx.SelectContext(ctx, q, &rows, `SELECT `+widgetEntityColumns+` `+widgetEntityFrom+` `+tail, args...); err != nil {
           return nil, err
       }
       out := make([]*widgetEntity, 0, len(rows))
       for _, row := range rows {
           out = append(out, &widgetEntity{Widget: row, Score: row.Sort})
       }
       return out, nil
   }
   ```
   A satellite (e.g. the tags per widget) = its own entity keyed by the widget uuid, generation
   `store.BuildGeneration()`, `Relate`d from the widget through a `json:"-"` field.
5. **Base + index + handler:**
   ```go
   func newRedifuWidgets(store *redifucache.Store) (*redifuWidgets, error) {
       c := &redifuWidgets{store: store}
       var err error
       if c.base, err = redifucache.NewBase[*widgetEntity](store, widgetEntityKey, redifucache.EntityTTL, widgetEntityShape); err != nil {
           return nil, err
       }
       if c.list, err = redifucache.NewList[*widgetEntity](store, c.base, widgetListKey, redifu.Ascending, widgetTables,
           func(ctx context.Context, tx *sqlx.Tx, p []string) ([]*widgetEntity, error) {
               return loadWidgets(ctx, tx, `WHERE w.user_uuid = $1 ORDER BY w.sort, w.uuid COLLATE "C"`, p[0])
           },
           func(p []string) string { return p[0] }); err != nil {
           return nil, err
       }
       store.Register(c)
       return c, nil
   }

   func (c *redifuWidgets) Tables() []string { return []string{"widgets"} } // + "widget_tags" if there is a satellite

   func (c *redifuWidgets) Apply(batch *redifucache.Batch, table string, changes []redifucache.Change) error {
       ctx, pipe := batch.Ctx, batch.Pipe
       keys, first := redifuChangeKeys(changes) // first change per key = the state in Redis
       current, err := loadWidgets(ctx, batch.Tx, `WHERE w.uuid = ANY($1)`, pq.Array(keys))
       if err != nil {
           return err
       }
       byKey := map[string]*widgetEntity{}
       for _, w := range current {
           byKey[w.UUID] = w
       }
       for _, key := range keys {
           old, now := first[key].Old(), byKey[key]
           stub := &widgetEntity{Widget: &models.Widget{Record: &redifu.Record{UUID: key}}}
           if oldOwner := old.Str("user_uuid"); old != nil && oldOwner != "" && (now == nil || now.UserUUID != oldOwner) {
               if err := c.list.Remove(ctx, pipe, stub, oldOwner); err != nil { // leave the old index
                   return err
               }
           }
           if now == nil {
               if err := c.base.WithPipeline(pipe).Del(ctx, stub); err != nil {
                   return err
               }
               continue
           }
           if err := c.base.WithPipeline(pipe).Set(ctx, now); err != nil {
               return err
           }
           if err := c.list.Add(ctx, pipe, now, now.UserUUID); err != nil { // enter / new score
               return err
           }
       }
       return nil
   }
   ```
   Satellite: `batch.Later("widget_tags:"+key, func() error { … reload through batch.Tx, Set … })`. Cross-owner view:
   `batch.LockGlobal("<name>")` in the handler, `SeedView` in the seed, `Serve(ctx, "*", tables...)` on read.
6. **Decorator** (`widget_cached_repository.go`):
   ```go
   type cachedWidgetRepository struct {
       WidgetRepositoryInterface
       cache *redifuWidgets
   }
   var widgetListColumns = []string{"uuid", "randid", "created_at", "updated_at", "user_uuid", "name", "sort"} // = the SQL SELECT

   func (r *cachedWidgetRepository) GetByUserUUID(ctx context.Context, owner string) ([]*models.Widget, *helper.ErrorLog) {
       scope := redifucache.NewReadScope(ctx)
       items, ok := r.cache.list.Read(scope, owner)
       if !ok {
           return r.WidgetRepositoryInterface.GetByUserUUID(ctx, owner)
       }
       out := make([]*models.Widget, 0, len(items)) // the empty shape must match SQL
       for _, item := range items {
           w := &models.Widget{Record: &redifu.Record{}}
           if err := redifucache.Project(w, item.Widget, widgetListColumns...); err != nil {
               return r.WidgetRepositoryInterface.GetByUserUUID(ctx, owner)
           }
           out = append(out, w)
       }
       return out, nil
   }
   ```
7. **Wiring:** in `providers.cacheReads`: `p.Widget, err = repositories.NewCachedWidgetRepository(p.Widget, store); must(err)`.
8. **Unit parity test** (§8.1): every kind of write (insert, content update, score update, owner move, delete,
   relation/satellite/junction change), flush, fallback = 0 when warm and after a flush, warm reads without SET/locks,
   one check per owner, empty outbox at the end.
9. **E2E parity test** (§8.3): probes (`Want`; `Ignore` only for fields that really change per request) and walks when
   paginated; modes warm, cold, flushAfter; a second instance.
10. **Guard tests** pass: `TestRedifuCachesTakeAGeneration`, `TestRedifuKeyFormats` (add the new format to the
    Shape/build list when relevant).
11. **Docs:** a new row in the "Already cached" table; for non-redifu keys, record the format, TTL, and flush impact.
12. **Release:** watch migration → deploy the binary. No other steps; new indexes are seeded on first read, and the
    lease guarantees that the drain uses the new build's rules.

The entity shape or the loader SQL changes later → `Shape` changes automatically. The meaning changes without the shape
changing → add `"rev N"`.

---

## 12. Building the engine in a new project

- **Library:** `github.com/21strive/redifu` (public) — pin the same version or a newer one with the `SetGeneration`,
  `Timeline.Extend`, `ErrNotSeeded`, `RawCodec` API.
- **`app/redifucache` engine:** if you already run this engine in another codebase, the fastest path is to **copy
  its `app/redifucache/` package** (with its tests), replace the module import path, and **drop one-off cutover code**
  (e.g. a `legacyFormats` list for migrating away from versioned keys). Keep every engine test; they are an executable specification. If
  the engine is rebuilt, this document (§4–§5) is its specification, and the §4.8 guarantees must be proven with the
  same tests.
- **Also bring along:** `app/buildinfo`, the repository helpers (`redifuChangeKeys`, `redifuReadScope`,
  `redifuPageBounds`, `redifuHandleUsable`, `RedifuAccounts` if there is an account entity), the test counters
  (`redifu_counting_test.go`), the e2e parity harness (`scripts/e2e/redifu_parity*.go`), the `redifu-purge` command,
  the `redifu-drain` worker, and the generation & format guard tests.
- **Bootstrap order:** `redifu_outbox` migration (template) → first entity & handler → decorator → unit parity test →
  e2e parity test → release. Start with the views that are read most often (usually the owner's lists and public
  pages).
- **Configuration:** `REDIFU_READS` (default `true`), `REDIFU_DRAIN_INTERVAL` (default `1s`, > 0), Redis ≥ 6.2 single
  node.
