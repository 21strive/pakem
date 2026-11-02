# 01 — Application architecture

The backend is **a single Go binary** (monolith) that serves the HTTP API, background workers, and one-off commands,
with PostgreSQL as the only source of truth and Redis only as a cache/short-lived state.
This document is the blueprint for its layers, folders, and code conventions. Code examples use illustrative entities
(`Booking`, `Availability`, `Widget`); replace them with your project's domain and keep the rules.

---

## 1. The big picture

### 1.1 One binary, three modes

The mode is selected by the first CLI argument:

| Mode | Command | Purpose |
|---|---|---|
| HTTP server | `go run ./app/cmd main` | Serves the REST API (Fiber) |
| Worker | `go run ./app/cmd worker [name]` | Background loops that run until SIGINT/SIGTERM. No name = **all** workers in one process |
| Command | `go run ./app/cmd command <name> [arguments]` | One-off jobs (backfill, purge, retry), then exits |

- All three share **the same connection bootstrap** (Postgres read, Postgres write, an extra pool when a library
  needs its own pool, Redis, S3/R2 client) and **the same layered architecture**.
- In production all three are **one Docker image**; the only difference is `command` in the ECS task definition
  (`["main"]` for the API service, `["worker"]` for the worker service). See [08-aws-infrastructure.md](08-aws-infrastructure.md).
- Commands that need no connections (e.g. creating local tables for e2e) are registered in one function
  (`constants.CommandNeedsNoConnections`) and run before the connections are opened.
- Commands **never** take the cache lease (see [04-caching.md](04-caching.md)): a one-off process only
  observes.

### 1.2 Request flow (the core of the architecture)

```
HTTP Request
   │
   ▼
Route (app/routes)            ── URL + method + middleware → controller method
   │
   ▼
Middleware (app/middlewares)  ── trace, auth (bearer → session → user), feature switch, access — via usecase
   │
   ▼
Controller (app/controllers)  ── orchestration: validation → usecase → response; the ONLY layer that knows HTTP
   │
   ▼
Validator (app/validators)    ── *fiber.Ctx → typed Request; caller identity written AFTER parse
   │
   ▼
UseCase (app/usecases)        ── one business capability; ownership check; owns the DB transaction
   │
   ▼
Repository (app/repositories) ── pure IO: SQL (sqlx); driver error → error kind; cache decorator for reads
   │
   ▼
PostgreSQL (read/write)  +  Redis (cache)
```

**Strict dependency direction:** outer layers depend on inner layers, never the other way around.

- **Controllers and middleware never call a repository.** Data only goes through a usecase.
- **A usecase may use any repository it needs**, and other usecases as long as they do not form a cycle.
- **Only the controller layer knows HTTP.** Inner layers state *what* went wrong as a `helper.Kind`;
  `responses.SendError` translates it into an HTTP status.
- This rule is **enforced by a test** (`go test ./app -run TestArchitecture`, §9), not just a convention.

All dependencies are assembled **once** at startup through **Providers** (§7) and passed on as interfaces.

### 1.3 One-line mental model

> **Route picks the handler, Middleware authenticates, Controller orchestrates, Validator parses,
> UseCase decides and transacts, Repository stores (and its decorator reads from the cache) — Provider
> assembles everything once.**

---

## 2. Tech stack

| Need | Choice |
|---|---|
| Language | Go (latest stable version; e.g. Go 1.25, image `golang:1.25-alpine`) |
| HTTP framework | `github.com/gofiber/fiber/v2` |
| SQL | `github.com/jmoiron/sqlx` + `github.com/lib/pq` (PostgreSQL) |
| Redis | `github.com/redis/go-redis/v9` + `github.com/21strive/redifu` (cache; see [04-caching.md](04-caching.md)) |
| Nullable columns | `github.com/guregu/null/v6` |
| Token | `github.com/golang-jwt/jwt/v5` |
| Logging | `log/slog` (structured JSON to stdout) |
| Test | `stretchr/testify`, `zhashkevych/go-sqlxmock`, `alicebob/miniredis/v2` |
| Mock | `mockery` (v2), configured in `.mockery.yml` |
| API docs | `swaggo/swag` (annotations → OpenAPI) **+ a mandatory Postman collection** in `app/specs/` |
| Cloud | `aws-sdk-go-v2` (S3 client used for Cloudflare R2, SES, DynamoDB, CloudWatch Logs) |
| Search | Typesense (self-hosted server) |

Internal libraries (e.g. a payment ledger) are **separate Go modules** in private repos, tagged with semver, and pulled
with `GOPRIVATE` + a token at build time (see the Dockerfile in [08-aws-infrastructure.md](08-aws-infrastructure.md)).

---

## 3. Folder structure

### 3.1 Top level

```
.
├── app/                     # all application code (§3.2)
├── AGENTS.md / CLAUDE.md    # conventions for contributors + agents (CLAUDE.md contains "see @AGENTS.md")
├── docs/                    # requirements/ plans/ handoffs/ reference/ (see 10-workflow.md)
├── migrations/              # sequential SQL: 001_*.sql, 002_*.sql, … (see 02-database.md)
├── backfills/               # one-off backfill SQL (not sequential, idempotent) + README.md
├── scripts/                 # helper & e2e programs, each with its own go.mod
│   └── e2e/                 # black-box HTTP tests against a running server (+ local/ stack, fakes)
├── Makefile                 # run / build / swagger / mock / e2e
├── Dockerfile               # production image (static binary CGO_ENABLED=0, arm64)
├── docker-compose.yaml      # optional, for running the image locally
├── .github/workflows/deploy.yml
├── go.mod / go.sum
├── CHANGELOG.md
└── .env.local / .env.staging  # non-production config examples (never contain production secrets)
```

Locally built binaries (`./cmd`, `./<app-name>`) are artifacts: add them to `.gitignore`.

### 3.2 `app/` — application layers

```
app/
├── cmd/             # main.go (mode dispatch) + connection.go (DB/Redis/R2/AWS bootstrap)
├── buildinfo/       # Revision + Time, stamped through -ldflags when the image is built
├── handlers/        # assembles the runtime per mode: http_handler (Fiber), worker_handler, command_handler
├── routes/          # route.go — URL table; provider → controller → Fiber
├── controllers/     # HTTP orchestration; init_controller.go = controller DI
├── validators/      # *fiber.Ctx → typed Request; takes the user from Locals
├── usecases/        # business logic; transaction boundaries; domain orchestration
├── repositories/    # data access; <entity>_repository.go; cache: <entity>_cache.go + <entity>_cached_repository.go
├── redifucache/     # cache engine (store, drain, seed, generation, lease) — see 04-caching.md
├── providers/       # singleton DI: repository_provider.go + usecase_provider.go (+ per-subsystem providers)
├── models/          # domain entities (embed *redifu.Record); db + json tags; setters
├── requests/        # inbound DTOs (+ *_request_swagger.go for documentation-only shapes)
├── responses/       # outbound DTOs + send_response.go / send_error.go (response writers)
├── middlewares/     # trace, oauth, feature flag, access/role, etc.
├── helper/          # ErrorLog + Kind, Response, logger, HTTP/map helpers
├── constants/       # enums & sentinel errors per domain (booking_constant.go, error_constant.go, …)
├── config/          # config.go — env → typed Configuration struct
├── database/        # opens the Postgres pool (DSN, TLS, binary parameters, timeout)
├── workers/         # background loops + init_worker.go (worker DI)
├── command/         # one-off commands + init_command.go (command DI)
├── notifications/   # example of a cross-domain subsystem (catalog, channels) — allowed, still obeys the import rules
├── search/          # search index client & schema (Typesense)
├── utils/           # stateless helpers + observability glue (logger handler, metrics)
├── mocks/           # mockery-generated mocks (do not edit by hand)
├── specs/           # generated OpenAPI + Postman collection (manual)
├── architecture_test.go + architecture_baseline.txt
└── error_log_test.go
```

**Naming rule:** files, structs, and entities use the same stem.
`booking` → `booking_controller.go`, `booking_validator.go`, `booking_usecase.go`, `booking_repository.go`,
`booking_model.go`, `booking_request.go`, `booking_response.go`. Usecase per capability:
`booking_reschedule_preview_usecase.go` (§5.4).

---

## 4. Entry point & runtime modes

`app/cmd/main.go`:

1. `init()`:
   - `time.Local = time.UTC` — the process always runs in UTC; user time zones are computed explicitly
     (see the time section of [03-api-design.md](03-api-design.md)).
   - `config.InitConfig()` → configuration struct.
   - A JSON `slog` logger to stdout (`AddSource: true`) is installed as the default (`slog.SetDefault`) and in
     `helper.SetLogger`; see [06-observability.md](06-observability.md).
   - Metrics are initialized once.
2. `main()`:
   - Parse the arguments; no arguments → print a usage text with **a list of every worker and command, each with a
     one-line description** (this list is operational documentation; update it when you add a worker/command).
   - Log one build line: `revision`, `built_at`, `mode`.
   - Open the shared connections **once**: Postgres read, Postgres write, library pool (if any), Redis, R2 client
     (S3) + presign client. Connections are never opened per request.
   - `switch` on the mode: `main` → `routes.NewHTTPRoute(...)` → `Listen`; `worker` → `workers.Init*Worker(...)`;
     `command` → `command.Init*Command(...)`.

`app/handlers/http_handler.go` assembles Fiber:

- `fiber.Config` with `ReadTimeout`/`WriteTimeout` 30 s and `IdleTimeout` 120 s (env `HTTP_READ_TIMEOUT`,
  `HTTP_WRITE_TIMEOUT`, `HTTP_IDLE_TIMEOUT`). The fasthttp timeouts bound the **connection**, not the handler; a slow
  handler is bounded by the DB transaction limits and the library call limits (see [02-database.md](02-database.md)).
  Request bodies are small (JSON); files **never** go through the API — clients upload directly to R2 with a presigned URL.
- Global middleware, in order: `TraceMiddleware` (a UUID per request in `Locals("trace_id")` + the
  `X-Trace-ID` header), `cors` (an **explicit** origin list, `AllowCredentials: true`, `ExposeHeaders` includes
  `X-Trace-ID`, `MaxAge` 86400), Fiber's `logger` (one line per request → input for latency analysis), `recover`
  with a stack trace.
- The CORS origin list is pinned by a test (`TestMainHttpHandlerCORSOrigins`) so it cannot change silently.
- `GET /health` for the ALB health check (declared without auth).

---

## 5. The layers in detail

Every layer component has the same shape: **an exported `Interface` → an unexported `struct` → a `New*()`
constructor that returns the interface**. Consumers depend on the interface, so it can be mocked.

### 5.1 Route (`app/routes/route.go`)

One function, `NewHTTPRoute(...)`:

1. Builds the providers once (§7).
2. Builds every controller from the providers.
3. Builds the middleware from the providers.
4. Declares the URL table.

```go
func NewHTTPRoute(ctx, cfg, dbRead, dbWrite, redis, r2Client, r2Presign, awsConfig) *fiber.App {
    repo := providers.NewRepositoryProvider(dbRead, dbWrite, redis)
    uc   := providers.NewUseCaseProvider(ctx, cfg, repo, dbRead, r2Client, r2Presign, awsConfig)

    bookingController := controllers.InitBookingController(repo, uc)
    // ... one per controller

    auth := middlewares.OauthMiddleware(uc.AuthSession)
    widgetsOn := middlewares.FeatureFlagMiddleware(config.IsWidgetEnabled) // accessor read per request

    f := handlers.MainHttpHandler(cfg)
    f.Get("/health", healthController.Check)
    f.Get("/booking", auth, bookingController.Get)
    f.Get("/booking/calendar", auth, bookingController.Calendar)       // static first…
    f.Get("/booking/:booking_uuid", auth, bookingController.Detail)    // …then parameterized
    f.Get("/widget", widgetsOn, auth, widgetController.List)           // feature switch goes first
    return f
}
```

- **Route order (Fiber matches in declaration order):** static/specific routes **before** parameterized
  routes. `/booking/calendar` must be declared before `/booking/:booking_uuid`, otherwise the literal
  `calendar` is captured as `:booking_uuid`.
- The **feature switch** (`FeatureFlagMiddleware`) is declared **first**, before auth: when it is off, the route
  answers 404 "This feature is not available yet." — an instant rollback with no data change.
- URL conventions, pagination, and the response contract: [03-api-design.md](03-api-design.md).

### 5.2 Controller (`app/controllers/`)

Thin orchestration. Per endpoint: call the validator → call the usecase → write the response. **No business logic,
no SQL, never a repository.**

- **More than one usecase only when the calls are independent:** they need not be atomic and there is no business
  decision between them. If one needs the other's result, or both must commit together, it is one usecase.
- **Errors are answered with `responses.SendError(c, errorLog)`**, which maps the kind to an HTTP status. Success goes
  through `responses.SendResponse`.
- Controllers carry **Swagger annotations** (`@Summary`, `@Tags`, `@Param`, `@Success`, `@Failure`, `@Router`) above
  every method; this is what generates `app/specs`.

```go
type AvailabilityControllerInterface interface {
    Create(c *fiber.Ctx) error
}

type availabilityController struct {
    availabilityUseCase   usecases.AvailabilityUsecaseInterface
    availabilityValidator validators.AvailabilityValidatorInterface
}

func NewAvailabilityController(uc usecases.AvailabilityUsecaseInterface, v validators.AvailabilityValidatorInterface) AvailabilityControllerInterface {
    return &availabilityController{availabilityUseCase: uc, availabilityValidator: v}
}

func (c *availabilityController) Create(cfiber *fiber.Ctx) error {
    request, errorLog := c.availabilityValidator.CreateValidator(cfiber)   // 1. validation
    if errorLog != nil {
        return responses.SendError(cfiber, errorLog)
    }
    data, errorLog := c.availabilityUseCase.Create(request)               // 2. usecase
    if errorLog != nil {
        return responses.SendError(cfiber, errorLog)
    }
    return responses.SendResponse(cfiber, &helper.Response{                // 3. response
        StatusCode: http.StatusCreated,
        Data:       responses.NewAvailabilityCreateResponse(data),
    })
}
```

### 5.3 Validator (`app/validators/`)

Owns everything `*fiber.Ctx`: parsing the body/query/params, and taking the authenticated user from
`c.Locals("user")` (set by the auth middleware). Returns a typed `*requests.X` or a `*helper.ErrorLog`.
`*fiber.Ctx` never enters a usecase.

- **Caller identity is written AFTER parsing, never before.** Parsers bind any matching key to a field
  (`encoding/json` is case-insensitive; form/query decoders bind by field name), so an identity written earlier can
  be overwritten by the request. Identity fields use `json:"-"` — plus `form:"-"`/`query:"-"` when the struct is
  parsed from a form/query — so no request can name them.
- **Errors are kinds too:** `helper.KindInvalid` for a bad request, `helper.KindUnauthenticated` when there is no session.

```go
func (v *availabilityValidator) CreateValidator(c *fiber.Ctx) (*requests.AvailabilityCreate, *helper.ErrorLog) {
    body := &requests.AvailabilityCreate{}
    if err := c.BodyParser(body); err != nil {
        return nil, helper.NewErrorLog(err, helper.KindInvalid)
    }
    user, ok := c.Locals("user").(*models.User)
    if !ok || user == nil {
        return nil, helper.NewErrorLog(constants.ERROR_USER_NOT_AUTHENTICATED, helper.KindUnauthenticated)
    }
    body.UserUUID = null.StringFrom(user.UUID)   // after BodyParser: no body key can name the caller
    return body, nil
}
```

### 5.4 UseCase (`app/usecases/`)

The core of the business logic:

- Takes a typed request, returns a **model or result struct** (not a `responses.*` DTO; mapping to the response
  shape is a pure function in `app/responses`).
- **Owns the transaction boundary** (begin/commit/rollback, §8.3).
- Orchestrates several repositories and other usecases.
- Never imports Fiber or HTTP types, and never picks an HTTP status.

Rules:

- **One business capability per usecase** — reschedule, booking questions, voucher purchase — not one usecase
  per entity. Name `<Domain><Capability>Usecase`, file `<domain>_<capability>_usecase.go`. A usecase only takes the
  repositories and usecases that capability uses.
- **Ownership is always checked.** Every resource identified by client input — path, query, or body, including
  foreign keys in the body — is loaded and confirmed to belong to the caller **before** anything is read or written on
  its behalf. "Does not exist" and "not yours" get the **same** answer: `helper.KindNotFound` with the same text, so the
  caller learns nothing about other accounts' ids. One helper per resource (`ownedService`, `ownedBooking`), called
  before the transaction is opened, or as the first read inside the transaction when the row must be locked
  (`ownedBookingForUpdate` → `SELECT … FOR UPDATE`).
- **Branch on facts, not statuses:** `errorLog.IsNotFound()`, `errorLog.IsKind(helper.KindConflict)`,
  `errorLog.Is(sentinel)` — never `errorLog.StatusCode == http.StatusNotFound`.

```go
type AvailabilityUsecaseInterface interface {
    Create(request *requests.AvailabilityCreate) (*models.Availability, *helper.ErrorLog)
}

type availabilityUseCase struct {
    availabilityRepository repositories.AvailabilityRepositoryInterface
    serviceRepository      repositories.ServiceRepositoryInterface
    generalRepository      repositories.IGeneralRepository
}
```

#### Splitting a fat usecase by capability

A usecase that grows to dozens of methods (e.g. a `bookingUsecase` and a `userUseCase` that grew to ±70 methods each)
is split **one capability at a time**:

1. Move that capability's methods to `<domain>_<capability>_usecase.go` with its own interface, struct, and `New…`.
   The struct holds only the repositories/usecases those methods use.
2. Logic shared with what stays behind becomes **functions** that take the repositories they read
   (`findOwnedBooking`, `rescheduleSpan`) — never a base struct, and never one capability calling another
   capability's struct. The ownership check moves along with the method.
3. Return the model/result (`models.BookingReschedulePreview`) and map it in the controller with a pure function
   (`responses.NewBookingReschedulePreviewResponse`).
4. **One path only:** build it once in `UseCaseProvider`, hand it to the controller, remove the method from the old
   interface & struct, regenerate the mocks, move its tests.
5. Nothing visibly changes for clients: the same responses, errors, and side effects.

New projects: **start per capability right away**; do not wait for a usecase to get fat.

### 5.5 Repository (`app/repositories/`)

Data access. A standard repository (`<entity>_repository.go`) holds the `dbRead` and `dbWrite` handles.

- **Reads** go through `dbRead`; **writes** take a `*sqlx.Tx` from the usecase and use the write pool.
- INSERT/UPDATE are built dynamically (collecting `$1,$2,…` placeholders) so only the fields that are set are written.
- **Pure IO:**
  - **Driver errors become kinds:** `sql.ErrNoRows` → `helper.KindNotFound`, unique violation → `helper.KindConflict`,
    anything else → `helper.KindInternal`. Driver text **never** becomes the message to the client (it names tables and
    constraints); `helper.NewErrorLog` keeps it for the log only.
  - **No input validation and no user-facing messages** — those are the validator's and the usecase's job.
  - **No HTTP DTOs** (`requests.*`, `responses.*`): filters and projections are structs owned by the repository or
    models (enforced by the architecture test).
  - **Writes on owned rows carry the owner** (`… WHERE uuid = $n AND user_uuid = $m`) as a second layer behind the
    usecase's ownership check, and answer `KindNotFound` when they touch no rows.

```go
type AvailabilityRepositoryInterface interface {
    Insert(tx *sqlx.Tx, data *models.Availability) *helper.ErrorLog              // write: needs a Tx
    Update(tx *sqlx.Tx, data *models.Availability) *helper.ErrorLog
    GetByUUID(availabilityUUID string) (*models.Availability, *helper.ErrorLog)  // read: no Tx
}

type availabilityRepository struct {
    dbRead, dbWrite *sqlx.DB
}
```

`IGeneralRepository` is special: only `BeginTransaction() (*sqlx.Tx, *helper.ErrorLog)` — the only place where a
transaction is started.

> **Cache:** repositories read and write Postgres; **writes never depend on Redis and never touch it**. The cache
> follows the writes on its own: a row trigger queues every change to a watched table into `redifu_outbox`, and a
> drain applies it to Redis. Cached reads are a **decorator** that wraps the SQL repository
> (`<entity>_cached_repository.go`), overrides only the read methods it serves, answers exactly like SQL, and falls
> back to SQL whenever the cache cannot answer. The old patterns — writing the cache inside a repository write, or a
> cache-first "fetcher repository" — are **forbidden**. Full details:
> [04-caching.md](04-caching.md).

---

## 6. Cross-layer building blocks

### 6.1 Model (`app/models/`)

Domain entities embed the **`*redifu.Record`** base (`github.com/21strive/redifu`), which carries identity and
audit fields: `UUID`, `RandId`, `CreatedAt`, `UpdatedAt`. Models carry `db:"…"` and `json:"…"` tags, use `null.*` for
optional columns, provide **setters** (a setter may validate and return a `*helper.ErrorLog`), and have an
**initiator** `New<Entity>()` that calls `redifu.InitRecord`.

```go
type Booking struct {
    *redifu.Record                     // UUID, RandId, CreatedAt, UpdatedAt
    UserUUID string      `json:"user_uuid" db:"user_uuid"`
    Status   string      `json:"status" db:"status"`
    Note     null.String `json:"note" db:"note"`
}

func (m *Booking) SetNote(note null.String) { m.Note = note }

func NewBooking() Booking {
    booking := &Booking{}
    redifu.InitRecord(booking) // allocates the Record, mints UUID + RandId, CreatedAt = UpdatedAt = now (UTC)
    return *booking
}
```

`UUID` is the internal identity & relation key; `RandId` is a short random id that is safe to use in public
URLs/cursors. Column conventions: [02-database.md](02-database.md).

#### Initiator `New<Entity>()`: every entity has one, every new instance comes from it

- **Every entity has an initiator `New<Entity>()`** in its model file (`booking_model.go` → `NewBooking()`), in the
  shape above: allocate the struct, call `redifu.InitRecord` on it, return it. `InitRecord` allocates the embedded
  `*redifu.Record`, mints `UUID` (v4) and `RandId` (16 characters from `crypto/rand`), and sets `CreatedAt` =
  `UpdatedAt` = now (UTC). `InitRecord` is called **only** inside initiators, so the Go code mints identities in one
  place.
- **A new instance is created only through its initiator**, then filled field by field (setters or assignments):

  ```go
  booking := models.NewBooking()
  booking.UserUUID = request.UserUUID.String // the caller, written by the validator
  booking.Status = constants.BOOKING_STATUS_PENDING
  booking.SetNote(request.Note)
  if errorLog := u.bookingRepository.Insert(tx, &booking); errorLog != nil {
      return rollbackAndReturn(errorLog)
  }
  ```

- **Never write a new entity inline as a struct literal:**

  ```go
  // Record is nil: booking.UUID panics, redifu panics on its first method call, json.Marshal silently drops uuid/randid
  booking := models.Booking{UserUUID: request.UserUUID.String, Status: constants.BOOKING_STATUS_PENDING}

  // identity minted by hand: a second copy of InitRecord that drifts (here RandId and UpdatedAt are forgotten)
  booking := models.Booking{Record: &redifu.Record{UUID: uuid.NewString(), CreatedAt: time.Now()}, UserUUID: …}

  // InitRecord outside the initiator: identities are minted all over the codebase again
  booking := &models.Booking{UserUUID: …, Status: …}
  redifu.InitRecord(booking)
  ```

  One initiator per entity keeps every new identity correct by construction, and `grep 'models.NewBooking('` lists
  every place a booking is born. Tests follow the same rule: `models.NewBooking()`, then set the fields the test pins.
- **Never use the initiator for a row that already exists**: it already has its identity, and a freshly minted randid
  orphans every index that points at it.
  - Read from the database: sqlx allocates the embedded `Record` while it scans; a hand-written `rows.Scan` allocates
    it without minting: `&models.Booking{Record: &redifu.Record{}}`.
  - Updated: load the row (`ownedBookingForUpdate`), change it through setters, write it back.
  - In the cache: a projection target starts empty (`&models.Booking{Record: &redifu.Record{}}`) so that the columns
    the SQL query does not select stay zero, as sqlx leaves them; a key-only stub carries only its key
    (`Record: &redifu.Record{UUID: key}`). See [04-caching.md](04-caching.md) §2.5 and §11.

#### Everything the cache stores embeds `*redifu.Record`

**Every object the cache stores embeds `*redifu.Record`**: the cache is redifu, and `*redifu.Record` is what satisfies
`redifu.Blueprint`. Domain entities already embed it; so does a cached model whose table is keyed by a business key
instead of `uuid`/`randid`, and so do the satellites, handles, and computed records the cache stores
([04-caching.md](04-caching.md) §2.5). No object reaches redifu with a nil `Record`: redifu panics on its first method
call.

### 6.2 Request & Response

- `app/requests/` — inbound DTOs (`AvailabilityCreate`, `BookingListQuery`). `*_request_swagger.go` may hold
  documentation-only shapes.
- `app/responses/` — outbound DTOs (`AvailabilityCreateResponse`) + pure mapping functions `New…Response(model)` +
  the response writers `send_response.go` and `send_error.go`.

### 6.3 Errors — `*helper.ErrorLog` with `helper.Kind`

**Never return a raw `error` across layers.** Wrap it with `helper.NewErrorLog(err, kind, opts...)`.
Inner layers state *what* went wrong; only `app/responses` maps it to HTTP.

| Kind | Situation | HTTP (only `responses` maps it) |
|---|---|---|
| `KindInvalid` | Bad input, validation failed | 400 |
| `KindUnauthenticated` | No valid session | 401 |
| `KindForbidden` | Caller is known but not allowed | 403 |
| `KindNotFound` | Does not exist — or does not belong to the caller | 404 |
| `KindConflict` | Duplicate, conflicts with the current state | 409 |
| `KindGone` | Existed once, no longer valid (expired link) | 410 |
| `KindUnprocessable` | Well-formed, but rejected by a business rule | 422 |
| `KindUpstream` | A dependency the request needs did not answer | 424 |
| `KindRateLimited` | Too many attempts | 429 |
| `KindUnavailable` | The feature cannot be served right now; masked like Internal | 503 |
| `KindInternal` (default) | Anything else | 500 |

This table exists **once**, in `helper.HTTPStatusOf`; only `app/responses` calls it (architecture test).
Message rules, sentinels, and the error JSON shape: [03-api-design.md](03-api-design.md).

Cross-layer signatures: `(T, *helper.ErrorLog)`, `*helper.ErrorLog`, or `(T, int64, *helper.ErrorLog)` for paginated
reads (data + total).

### 6.4 Middleware (`app/middlewares/`)

Middleware follows the controller rules: data goes **through a usecase, never a repository**.

- `TraceMiddleware()` — `trace_id` per request (log + header + error response).
- `OauthMiddleware(authSessionUsecase)` — bearer token → `AuthSessionUsecase.Authenticate` → user in
  `c.Locals("user")`; the session is rejected if the password changed after the token was issued.
- `FeatureFlagMiddleware(enabled func() bool)` — 404 when the switch is off.
- Access/role middleware (admin, staff, account status) — always through a usecase.

### 6.5 Config (`app/config/`)

`config.InitConfig()` loads `.env` (godotenv) into a typed `Configuration` struct (`App`, `HTTP`,
`Database.Postgres.Read/Write/Transaction`, `Redis`, `R2`, one block per integration). Access it through `config.Get()`.

- **Precedence:** `godotenv.Load()` **does not override** env vars that already exist. On ECS all configuration arrives
  as env vars; the image carries only an **empty** `.env` (godotenv fails if the file does not exist).
- **A key that is present but empty still "exists":** setting `KEY=""` in the task definition overrides the `.env`
  value with an empty string. Keys that have no value yet are **commented out**, not emptied.
- **Booleans are written exactly as `"true"`/`"false"`.** `strconv.ParseBool` rejects an unknown value (`"yes"`) and the
  config helper silently falls back to the default — no error reaches anyone. Document each switch's default in the code
  and in the tfvars.
- Invalid configuration that makes the system dangerous (e.g. an unknown TLS mode) → **fail to start**; do not
  silently use a default. The process must also fail to start on: `JWT_API_SECRET` < 32 bytes outside `ENVIRONMENT=local`,
  and env vars that redirect third-party endpoints to stand-ins (`*_BASE_URL`, `*_ENDPOINT`, `EMAIL_SINK_DIR`) outside `local`.
- Mistyped numeric/duration values (`0`, `ten`) fall back to the default **and are announced on stderr** (`config: … using …`).
- **Renaming an env var without breaking a deploy:** the helper `getEnvStringDeprecated(key, deprecatedKey, default)` reads
  the new name first, then the old name while printing a "rename it" warning at startup. Names follow the **provider**,
  not the service (`CLOUDFLARE_ACCESS_KEY_ID`, not `R2_ACCESS_KEY_ID`).
- `getEnv` strips one pair of quotes around the value (env vars from an IDE are sent verbatim) and trims it (a newline
  from a secret mount breaks HMAC).

### 6.6 Constants (`app/constants/`)

Enums and sentinel errors per domain, one file per area (`booking_constant.go`, `error_constant.go`).
SCREAMING_SNAKE_CASE names: `BOOKING_STATUS_COMPLETED`.

- Sentinel errors: `ERROR_<DOMAIN>_<WHAT>`. Text that names a request field: `ERROR_FIELD_<FIELD>_<WHAT>`
  (`ERROR_FIELD_BOOKING_UUID_REQUIRED` for `"booking_uuid is required"`); path/query parameters:
  `ERROR_PARAM_<NAME>_<WHAT>`. Before adding one, search for a sentinel with the same text and reuse it.

### 6.7 Observability

The logger, `trace_id`/`error_id`, the error tracker, and metrics are installed **once in `main.init()`** so all three
modes are covered. Details: [06-observability.md](06-observability.md).

---

## 7. Dependency injection — the Provider pattern

The part most worth copying. Every repository and every reused usecase is **built exactly once**
and shared (stateless: it only holds DB/Redis handles and config), then handed to thin `Init*` functions.

### 7.1 `RepositoryProvider` (`app/providers/repository_provider.go`)

```go
type RepositoryProvider struct {
    Booking repositories.BookingRepositoryInterface
    General repositories.IGeneralRepository
    User    repositories.UserRepositoryInterface
    // ... one field per entity
}

func NewRepositoryProvider(dbRead, dbWrite *sqlx.DB, redis redis.UniversalClient) *RepositoryProvider {
    p := &RepositoryProvider{
        Booking: repositories.NewBookingRepository(dbRead, dbWrite),
        General: repositories.NewGeneralRepository(dbWrite),
        User:    repositories.NewUserRepository(dbRead, dbWrite),
    }
    p.cacheReads(redis) // wraps each repository that has a cache in its decorator (04-caching.md)
    return p
}
```

### 7.2 `UseCaseProvider` (`app/providers/usecase_provider.go`)

Holds the **heavy, reused** usecases — the ones many controllers use: core domain usecases, cross-cutting
capabilities (auth, object storage), and third-party integration wrappers. The graph is built **from the leaves**
(dependencies before their consumers). Large subsystems may have their own provider (`ledger_provider.go`, `queue_provider.go`).

```go
func NewUseCaseProvider(ctx, cfg, repo *RepositoryProvider, dbRead, r2Client, r2Presign, awsConfig) *UseCaseProvider {
    serviceUseCase      := usecases.NewServiceUsecase(repo.Service, repo.Availability, repo.General)
    availabilityUseCase := usecases.NewAvailabilityUsecase(repo.Availability, repo.Service, repo.General)
    userUseCase         := usecases.NewUserUseCase(ctx, repo.User, serviceUseCase, availabilityUseCase)
    return &UseCaseProvider{User: userUseCase, Service: serviceUseCase /* ... */}
}
```

### 7.3 Controller DI (`app/controllers/init_controller.go`)

`Init*Controller(repo, uc)` builds only what is **unique** to that controller (specific usecases + the validator), and
takes the shared ones from the providers:

```go
func InitBookingController(repo *providers.RepositoryProvider, uc *providers.UseCaseProvider) BookingControllerInterface {
    bookingUseCase := usecases.NewBookingUsecase(config.Get(), repo.Booking, repo.BookingPayment, uc.User)
    return NewBookingController(bookingUseCase, validators.NewBookingValidator())
}
```

**Why:** before providers, every `Init*` built its own graph — the same repositories and usecase graph were
built over and over. Providers reduce this to one construction site per dependency.

### 7.4 Worker & command DI

`app/workers/init_worker.go` and `app/command/init_command.go` apply the same `Init*` idea to their runtimes
(building only the subset of dependencies that worker/command needs). Worker details: [05-workers-and-integrations.md](05-workers-and-integrations.md).

---

## 8. Conventions summary

### 8.1 The interface/struct/constructor trio

```go
type XRepositoryInterface interface { ... }    // Interface suffix (some use an I prefix: IGeneralRepository)
type xRepository struct { ... }                // unexported
func NewXRepository(...) XRepositoryInterface  // returns the interface
```

### 8.2 Imports — 3 groups separated by blank lines

```go
import (
    "context"                          // 1. stdlib
    "net/http"

    "github.com/gofiber/fiber/v2"      // 2. third-party
    "github.com/jmoiron/sqlx"

    "github.com/<org>/<app>/app/config" // 3. internal
    "github.com/<org>/<app>/app/models"
)
```

### 8.3 Transaction pattern (in the usecase)

```go
tx, errorLog := u.generalRepository.BeginTransaction()
if errorLog != nil {
    return nil, errorLog
}
rollbackAndReturn := func(e *helper.ErrorLog) (*models.Booking, *helper.ErrorLog) {
    tx.Rollback()
    return nil, e
}

booking, errorLog := u.ownedBookingForUpdate(tx, request.BookingUUID, request.UserUUID) // first read: locks the row
if errorLog != nil {
    return rollbackAndReturn(errorLog)
}
if errorLog = u.bookingRepository.Update(tx, booking); errorLog != nil {
    return rollbackAndReturn(errorLog)
}
if err := tx.Commit(); err != nil {
    return nil, helper.NewErrorLog(err, helper.KindInternal)
}
```

- Outbound side effects (email, push, third-party API calls) are **not** performed inside the transaction: write an
  outbox row in the same transaction and let a worker send it (see [05-workers-and-integrations.md](05-workers-and-integrations.md)).
- Do not hold a transaction open while waiting on the network; transaction time limits are explained in [02-database.md](02-database.md).

### 8.4 Nullable columns

```go
null.StringFrom("x")  // valid value
null.String{}         // SQL NULL
if data.BookingID.Valid { use(data.BookingID.String) } // always check .Valid
```

### 8.5 Naming

| Item | Pattern | Example |
|---|---|---|
| Interface | `<Name>Interface` | `BookingRepositoryInterface` |
| Constructor | `New<Name>` | `NewBookingRepository`, `NewBookingUsecase` |
| Entity initiator (calls `redifu.InitRecord`, §6.1) | `New<Entity>()` | `NewBooking()` |
| Capability usecase | `<Domain><Capability>Usecase` | `BookingReschedulePreviewUsecase` |
| Request DTO | `<Domain><Action>…` | `AvailabilityCreate` |
| Response DTO | `<Domain><Action>Response` | `BookingCreateResponse` |
| Constant | `SCREAMING_SNAKE` | `BOOKING_STATUS_COMPLETED` |
| Sentinel error | `ERROR_<DOMAIN>_<WHAT>` | `ERROR_BOOKING_NOT_FOUND` |
| Test package | `<layer>_test` | `package usecases_test` |
| Metric | `domain.event` (dots), dimensions in attributes | `booking.created` |

---

## 9. Tests that guard the architecture

- **Architecture test** (`app/architecture_test.go`, part of `go test ./...`): allowed imports per package
  (§1.2), no `http.Status*` in repositories, models, validators, and usecases (except clients that actually make
  outbound HTTP calls), only `app/responses` maps kinds to statuses, repositories do not import
  `requests`/`responses`. Existing violations are recorded in `app/architecture_baseline.txt`; a new violation fails the
  test, **and a baseline entry that no longer occurs also fails the test** — the baseline can only
  shrink. After fixing: `ARCHITECTURE_BASELINE_UPDATE=1 go test ./app -run TestArchitecture`.
  New projects start with an **empty** baseline.
- **Error-message test** (`app/error_log_test.go`): no `NewErrorLog` message option repeats the `err` text,
  and no 4xx error read by clients is built from fixed text at the call site (it must be a sentinel). No
  baseline.
- **Generation test** (`TestRedifuCachesTakeAGeneration`): caches are built only through the `redifucache` constructors.
- Other tests (usecase, repository, cache parity, e2e): [07-testing-and-e2e.md](07-testing-and-e2e.md).

---

## 10. Adding a feature — file order

For a new entity `Widget` (the full cross-repo checklist is in [11-checklists.md](11-checklists.md)):

1. **Migration** — `migrations/NNN_widgets.sql` ([02-database.md](02-database.md)).
2. **Model** — `app/models/widget_model.go` (embed `*redifu.Record`, `db`/`json` tags, setters, and the initiator
   `NewWidget()` that calls `redifu.InitRecord`; every new widget is created through it, §6.1).
3. **Repository** — `app/repositories/widget_repository.go` (interface + struct + `NewWidgetRepository`; reads through
   `dbRead`, writes take a `*sqlx.Tx`) → a field in `RepositoryProvider`. Cache (if needed) = a redifu decorator
   ([04-caching.md](04-caching.md) §"Adding a cache").
4. **DTOs** — `app/requests/widget_request.go`, `app/responses/widget_response.go` (+ pure mapping functions).
5. **UseCase** — `app/usecases/widget_<capability>_usecase.go` (its own transaction, an `ownedWidget` helper) → into
   `UseCaseProvider` if several controllers use it; otherwise it is built in the controller's `Init*`.
6. **Validator** — `app/validators/widget_validator.go`.
7. **Controller** — `app/controllers/widget_controller.go` (Swagger annotations) + `InitWidgetController` in
   `init_controller.go`.
8. **Route** — `app/routes/route.go` (static before parameterized; the feature switch goes first if there is one).
9. **Tests** — usecase (including a resource owned by another account: rejected, nothing written) + repository + e2e.
10. **API spec (mandatory)** — `make gen-swagger` **and** a new request in the Postman collection in `app/specs/`.
11. **Docs** — `docs/reference/...` if the logic is non-trivial; CHANGELOG.
12. **Architecture** — `go test ./app -run TestArchitecture` stays green.
