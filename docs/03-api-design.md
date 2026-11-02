# 03 — Endpoint design, contracts, auth, security, client handoff

The HTTP contract used by every client (web, dashboard, mobile), how authentication & sessions work, per-endpoint
security rules, and how the backend hands the contract over to the frontend team/agent.

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Response contract

### 1.1 Single envelope

One struct for every JSON response, success and error alike (`app/helper/model.go`):

```go
type Response struct {
    StatusCode    int         `json:"status_code"`
    StatusMessage string      `json:"status_message"`          // "Success" | "Failed"
    Message       string      `json:"message,omitempty"`
    ErrorID       string      `json:"error_id,omitempty"`      // 5xx only
    Data          any         `json:"data,omitempty"`
    Pagination    *Pagination `json:"pagination,omitempty"`    // offset lists only
    ErrorLog      *ErrorLog   `json:"-"`
}
type Pagination struct {
    Page    int64 `json:"page"`
    PerPage int64 `json:"per_page"`
    Total   int64 `json:"total"`
}
```

Exact examples:

```json
{"status_code":201,"status_message":"Success","data":{"availability_uuid":"0d3c5a52-7d0e-4c1b-9a43-2f3c9d6c1e11"}}
{"status_code":200,"status_message":"Success","data":{"bookings":[]},"pagination":{"page":1,"per_page":10,"total":42}}
{"status_code":200,"status_message":"Success","message":"Pong"}
{"status_code":404,"status_message":"Failed","message":"Booking not found."}
{"status_code":409,"status_message":"Failed","message":"Service already has a discount in this period","data":{"conflicts":[]}}
{"status_code":400,"status_message":"Failed","message":"Password is too common.","data":{"reason":"common"}}
{"status_code":500,"status_message":"Failed","message":"Internal server error","error_id":"ERR_9KQZV4MNBT3A2WXE"}
```

- `status_code` repeats the HTTP status (a client that reads only the body still knows it). `trace_id` is **not** in the
  body — only in the `X-Trace-ID` header and the logs.
- **MUST** `200 <= code < 300` = `"Success"` (a writer that treats only 200/201 as success turns a 202 into "Failed").
- **MUST** `data` on a 4xx comes only from `helper.NewErrorLogWithData`; a 5xx **never** carries `data`; if the controller
  also sets `Data`, the controller's data wins (pinned by a test).
- **SHOULD** an empty list is `[]`, never `null`; lists are wrapped in a named object (`data.bookings`) so metadata
  (`next_cursor`) can be added without breaking clients.

### 1.2 Kind → status, default text, masking, log

| Kind | HTTP | Default text | To the client | Log |
|---|---|---|---|---|
| `KindInvalid` | 400 | `Invalid request data.` | message passed through | WARN |
| `KindUnauthenticated` | 401 | `You do not have permission to perform this action.` | passed through | WARN |
| `KindForbidden` | 403 | `You do not have permission to perform this action.` | passed through | WARN |
| `KindNotFound` | 404 | `Failed to load data.` | passed through | WARN |
| `KindConflict` | 409 | `The request conflicts with the current state of the data.` | passed through | WARN |
| `KindGone` | 410 | `This is no longer available.` | passed through | WARN |
| `KindUnprocessable` | 422 | `The request could not be processed.` | passed through | WARN |
| `KindUpstream` | 424 | `A service this request depends on did not answer. Please try again later.` | **passed through** — write the message deliberately | WARN |
| `KindRateLimited` | 429 | `Too many requests.` | passed through | WARN |
| `KindInternal` | 500 | — | `Internal server error` + `error_id` | ERROR |
| `KindUnavailable` | 503 | — | `Internal server error` + `error_id` | ERROR |

- `error_id` = `"ERR_"` + 16 Crockford Base32 characters (80 random bits), created by `NewErrorLog` for server faults
  only. The UI shows it on a 5xx as material for the user's report.
- Masking is tied to the kind (`Kind.IsServerFault()`), not to the number.
- **Database timeouts become 503 automatically**: `NewErrorLog` replaces any kind with `KindUnavailable` for `55P03`
  (lock_not_available), `57014` (statement_timeout), `25P03` (idle_in_transaction) — the client may retry.
- Driver text (`sql: `, `pq: `, `redis: `, also when wrapped) **never** becomes the message.
- Log: `>= 500` ERROR, `>= 400` WARN; fields `status_code`, `error_kind`, `error_id`, `trace_id`, the caller location for
  server faults, the `DiagCtx` fields ([06-observability.md](06-observability.md)).
- **MUST NOT** pass raw third-party error text through to a public endpoint (424 only with a message you wrote yourself,
  e.g. "Provider could not be read: … Nothing was changed.").

### 1.3 Headers

- **MUST** `X-Trace-ID` (a server-generated UUIDv4) on every response, exposed through CORS. **(improvement)** accept an
  incoming `X-Request-Id`/`traceparent` when present.
- `Cache-Control` per endpoint: real-time public data `no-store`; public directory `public, max-age=60`.
  **(improvement)** `no-store` as the default for responses that contain personal data.
- Downloads: `Content-Type` + `Content-Disposition` (exposed through CORS).

### 1.4 Responses outside the envelope & ErrorHandler

| Case | Shape |
|---|---|
| 204 No Content (delete without a body, public fire-and-forget) | no body |
| File (`.pkpass`, CSV) | bytes + `Content-Type`/`Content-Disposition`; errors stay JSON |
| Format required by a provider (e.g. webhook URL validation) | top level as the provider specifies |

- **MUST (improvement)** install your own `fiber.Config.ErrorHandler`: `*fiber.Error` and **panics** are wrapped in the
  envelope; a panic → `KindInternal`, masked with an `error_id`. Fiber's default handler answers a panic, and a body
  over the size limit, with `text/plain` that can carry internal text.
- A 404 for an unknown route **SHOULD** be JSON with `data.code: "ROUTE_NOT_FOUND"` (clients use "route does not exist
  yet" as the signal for preview mode — see §7.1).

### 1.5 Error messages

- **MUST: API messages to clients are in English; the clients translate them.** Web and mobile hold a translation table
  (key = the message in lowercase without the period); an unknown message is replaced with a fallback sentence. As a
  result, **the message text is part of the contract** — changing the text breaks the translation in two clients.
- **MUST (improvement)** every 4xx carries a **stable machine code** in `data.code` (e.g. `TOKEN_EXPIRED`,
  `FEATURE_DISABLED`, `PHONE_REQUIRED`); clients branch on the code, not on the text (`data.code`, or a field such as
  `data.reason`).
- Style: per-field messages are lowercase without a period, with the field name exactly as in the JSON
  (`"email is required"`, `"invalid payment_channel"`); business-rule messages are sentences with a period
  (`"Booking not found."`).
- Every 4xx text = a sentinel in `app/constants` (`ERROR_<DOMAIN>_<WHAT>`, `ERROR_FIELD_…`, `ERROR_PARAM_…`), guarded by
  `TestErrorLogCalls`. Text built from values (`items[%d].uuid is required`) may be inline.
- Text for end users (push, WhatsApp, email) is in the product's language and composed by the server/templates — it is
  not an API error message.

### 1.6 JSON data conventions

- **`snake_case` for every field.** (Models that embed `redifu.Record` emit camelCase `createdAt`/`updatedAt` when
  serialized directly — one more reason for the next rule.)
- **MUST NOT** serialize database models directly; always a DTO in `app/responses` built by a pure mapping function
  (when a model is serialized, every new column leaks out unnoticed).
- Money: integers in whole units; minor units end in `_minor`; basis-point rates in `_bp`. **MUST NOT** use float.
- Enums are `SCREAMING_SNAKE`; enum input is trimmed and case-insensitive.
- File = an **object key** relative to the bucket root (`user/<uuid>/avatar/<file>.webp`); the client adds the asset
  host.
- Phone numbers in E.164 (`+62…`), masked in public responses (`0812•••890`).
- Time: §8.

---

## 2. URLs & routes

### 2.1 Versioning & compatibility

- No version prefix (`/v1`). Compatibility is kept by:
  1. **additive changes only** (new fields are optional, the old path is still served — `page` still works even though
     `cursor` exists);
  2. **explicit client opt-in** (cursor mode is active only when the `cursor` parameter is present; capabilities are
     announced through `client_features` or a client capability header);
  3. **old clients are ignored, not rejected** when needed (a risky change without `confirm: true` is ignored).
- **MUST** assume old mobile builds stay alive for months; a change that breaks old clients needs a capability flag or a
  feature switch.
- **MUST** an internal refactor does not change `status_code`, `status_message`, `message`, `error_id`, `data` (except
  messages that leak internal details — recorded in the CHANGELOG).
- **(improvement)** a client capability header from day one: `X-<App>-Client: <platform>/<build>`, so the server can
  reject builds that are too old with a clear code.

### 2.2 Naming

- Multi-word segments in **kebab-case**: `/service-category`, `/reschedule-preview`, `/additional-charges`.
- Path params in **snake_case with the entity name**: `:booking_uuid`, `:service_uuid` (Swagger `{booking_uuid}`).
  **MUST NOT** use a generic `:uuid`/`:id`.
- Query params in snake_case: `per_page`, `search_value`, `start_date`, `sort_by`, `sort_dir`.
- **(improvement)** consistently **plural** collections (`/bookings`, `/services`) — never a mix of singular
  (`/booking`) and plural (`/resources`, `/admin/users`) routes.
- Non-CRUD actions: `POST /<res>/:id/<verb>` (`complete`, `reject`, `cancel`, `duplicate`, `merge`, `start`,
  `finish`, `recover`, `verify`, `resend`).
- Side-effect-free previews: `GET …/<x>-preview` (`/reschedule-preview`, `/move-preview`).
- Upload presign: `POST …/presign-<object>` (`/user/presign-avatar`).
- Public analytics endpoints: a path that ad blockers do not filter (`/booking-page/events`, not `/track`).
- **Methods:** `PATCH` merges the keys sent, then validates the whole object; `PUT` replaces the whole set/object and is
  idempotent (`PUT /customer/:uuid/tags`). **MUST NOT** put the uuid in the body for PATCH; **MUST NOT** put the action
  before the id (`/default/:id`).
- A body on `DELETE` only when the value is secret/long (the FCM token goes in the body so it is not written to the access
  log). **MUST NOT** put an email/token in the path (the access log records the path).

### 2.3 Namespaces

| Prefix | Contents | Auth |
|---|---|---|
| `/user/*` | auth flows (login, register, refresh, reset, verify) + profile/settings of the open account | declared per route |
| `/me/*` | per **login**: account switcher, logout, invitations | bearer of any account that belongs to that login |
| `/admin/*` | internal dashboard | bearer + ADMIN role (§9) |
| `/team/*` | business account team | bearer + access declaration (§6.2) |
| public via username | public pages | no auth, through the active-account gate |
| webhook | external providers | signature (§6.7) |
| `/health` | infrastructure | public |

- **(improvement)** one shape for public routes: `/public/:username/<res>` (not several competing shapes).
- **(improvement)** webhooks at `/webhook/<provider>/<event>` from the start, with the path taken from config/constants.
  A path already registered with a provider (and included in the signature, or matched exactly like Apple's Return URL)
  = a **permanent API**.
- **MUST keep a reserved-username list** in the backend **and** the clients when usernames share a namespace with web
  routes (`app.com/<username>`); add to it every time the web adds a top-level route.

### 2.4 Identifiers in URLs

| Identifier | For |
|---|---|
| `uuid` | resources owned by an account |
| `randid` | short public handles, old cursors |
| `username` | public pages |
| short code | tickets/queue |
| random token | invitation, purchase, reset links |

- **MUST: ownership never depends on a UUID being secret.** UUIDs leak in public payloads (e.g. a service's `user_uuid`
  on the public page) — that is what made the balance-withdrawal IDOR exploitable.
- UUID-based customer links (booking detail, payment page) are deliberately public **capability URLs**; **MUST** check
  that a child resource belongs to its parent (the transaction belongs to that booking).

### 2.5 Route table

- **One `NewHTTPRoute`, flat, one line per route, explicit middleware on every line** (no `f.Group`): AST tests read
  every `f.Get/Post/...` together with its arguments.
- Middleware order per route: **feature switch → (public gate | auth) → access declaration → field guard → subscription
  guard → handler**:
  ```go
  f.Post("/queue", queueFlag, oauthMiddleware, access(view(models.PAGE_QUEUE)), access(edit(models.PAGE_SERVICES)), queueController.Create)
  f.Get("/booking/:booking_uuid", activeOwnerByBooking, lenientOauthMiddleware, bookingController.GetDetail)
  ```
- **MUST** test static-before-param ordering with stub controllers that answer with their own name (every path lands on
  the right handler).
- **MUST** have the AST test `TestEveryAuthenticatedRouteDeclaresItsAccess`: every route behind auth declares its access;
  an access declaration without auth also fails.
- Auth middleware variants:
  - `OauthMiddleware` — bearer required; fills `Locals("user" | "login" | "member" | "session")`;
  - `OptionalOauthMiddleware` — no header passes, a bad header is rejected (accepting an invitation);
  - `LenientOauthMiddleware` — a bad token is ignored (a customer's public page must not break because of a stale token);
  - `Authorization: Machine <token>` for devices (§5.11).
- **Public gates** (`ActiveOwnerByUsername`, `ActiveOwnerByBooking`) in front of public routes: inactive account → 404 as
  if it did not exist; one check up front cannot be forgotten by a query added later.
- `/health`: 200 `"Pong"`; 503 only when the write pool does not hand out a connection within 2 s even though the DB
  answers ([02-database.md](02-database.md) §6.3).

### 2.6 Status per operation

| Operation | Status |
|---|---|
| Create | 201 + the object or its uuid |
| Action | 200; 201 when the action creates something |
| Update | 200 + the object after the change |
| Delete | **(improvement)** pick one: 204 without a body (do not mix 200 `{uuid}` and 204) |
| Asynchronous acceptance / anti-enumeration | 202 |
| Public fire-and-forget | always 204 |

### 2.7 Public endpoint inventory

**MUST** every public route has a written reason (class `PUBLIC-BY-DESIGN` in the ownership audit table, §6.1). Valid
categories: auth flows, public pages via username, customer capability URLs, price calculators, reference catalogs
(time zones, holidays, payment channels, templates), webhooks, `/health`, analytics events, invitation links, account
recovery & the account-deletion form.

---

## 3. Pagination & lists

### 3.1 Offset (small lists / admin)

- Query `page` (≥ 1) and `per_page`; the response is `data` + `pagination {page, per_page, total}` at envelope level.
- `per_page` has a per-endpoint default and a maximum of 100; values above the maximum are **clamped**. Invalid values →
  400 `"<name> must be a positive number"` (not a silent default).
- **MUST** `total` uses the same predicate as the page contents (one filter struct for `COUNT(*)` and the page).
- **MUST** use a total order with a tiebreak (`created_at DESC, uuid DESC`).

### 3.2 Cursor (growing lists)

- Active when the `cursor` parameter is present (first page `cursor=`); `per_page` defaults to 20, maximum 100 (clamped).
- **(improvement, one shape for every list)**:
  ```json
  {"status_code":200,"status_message":"Success","data":{"bookings":[],"next_cursor":"MTc5MjE2…","has_more":true}}
  ```
  Last page: `has_more:false`, `next_cursor:""`. (one shape for every cursor list — never several.)
- The cursor is **opaque** and represents a position (time score in µs + uuid, base64): deleted/changed rows do not
  shift the pages; new items appear after a refresh from `cursor=`.
- A broken cursor → 400 `"cursor is invalid"` (the client reloads from the start). Other filters must be the same on
  every page. **No total.**
- **MUST resolve the cursor inside the caller's scope** (a real hole: the wallet cursor lookup once searched the history
  of all sellers).
- SQL & its cache: [02-database.md](02-database.md) §3.5, [04-caching.md](04-caching.md) §4.5.

### 3.3 Filters, sorting, search

- Enum filters: empty = no filter; an unknown value → 400 with the valid values in the message
  (`"booking_status must be one of: INCOMING, COMPLETED, REJECTED"`).
- Date ranges `start_date`/`end_date` in `YYYY-MM-DD` come in pairs, verified by round-trip (31 February is rejected),
  `start ≤ end`, with a per-endpoint limit on the range length.
- Sorting only from a whitelist (`sort_by: date|amount|name`, `sort_dir: asc|desc`).
- Text search through Typesense: fetch one page of uuids from the engine → read the rows from Postgres, keeping the
  relevance order → filter again in Postgres (role, owner) → drop stale documents → `total` from the engine. **MUST** send
  the owner filter to the engine as well (`user_uuid:=…`); a search without an owner is rejected.

---

## 4. Request validation & DTOs

- **Fiber JSON binding = `encoding/json`**: keys are matched **case-insensitively, including Unicode folding**
  (`"useruuid"`, `"UserUUID"`, `"uſername"` with the letter ſ). Consequences:
  - **MUST** tag every identity field `json:"-"` (+ `query:"-"`/`form:"-"`). Incident: an untagged `UserUUID` field in
    the balance-withdrawal DTO → the body `{"useruuid": "<victim>"}` withdrew another seller's balance.
  - **MUST** guards that read raw keys use `strings.EqualFold`. Incident: a team member got past a guard with
    `"Timezone"` or `"uſername"`.
  - Validator tests use a real Fiber app with `Locals("user")` = the attacker and a body with every spelling of the
    identity keys — the result must always be the caller's identity.
- **PATCH:** optional fields are pointers or `null.*`. The binder does not tell absent from `null`; when the semantics
  differ, the validator checks the raw key and sets `XxxSet bool json:"-"`. The semantics are written in the DTO comment &
  Swagger: `absent/null → unchanged; "" → remove; value → set` (lists: `[] → remove all`). Merge first, then validate the
  whole object.
- **Normalization in the validator:** trim, enums to uppercase, canonical time zones, E.164 phone numbers, exact dates.
- **Parse errors:** **MUST** use a fixed message (`"Invalid request body"`, `"invalid query parameters"`), **MUST NOT**
  pass the parser text through (`encoding/json`/Fiber messages are not written for clients).
- Unknown fields are ignored.
- **Check order:** role authorization (e.g. admin) **before** the query/path/body is read (a non-admin learns nothing from
  a 400) → existing checks → new rules → all of it finishes before anything is written/hashed.
- **Public input limits:** every free text has a length limit, every list a size limit (e.g. email 254, reason 2000, at
  most 50 tokens per logout).

---

## 5. Authentication & sessions

### 5.1 Data model

| Concept | Table (example) | Contents |
|---|---|---|
| identity (login) | `logins` | unique email (trim + lowercase), password hash + `password_ts`, Google/Apple subject, email verification, last opened account |
| tenant (account) | `users` | business data; `owner_login_uuid` |
| session | `user_sessions` | one row per (login, account, member, device): sha256 of the refresh token, expiry, `revoked_at` |
| membership | `team_members` | a login as a member of someone else's account, with per-page access |

**SHOULD** separate identity, tenant, and session from the start (splitting them later takes expand → fill → narrow over
several releases + a switch).

### 5.2 Tokens

- JWT HS256. Access (e.g. 168 hours) contains `uuid` (the open account), `login_uuid`, `member_uuid`,
  `session_uuid`, `password_timestamp`, plus display info; the `role` in the token is only for client routing — **the
  server does not trust it**. Refresh (720 hours) contains `user_uuid`, `session_uuid`, a random `jti` (stored as a hash,
  must be unique).
- A long access lifetime is acceptable only because **the session is read from the DB on every request** (§5.3). Without
  that: 15–60 minutes.
- **MUST (improvement):**
  1. a `typ`/`aud` claim per token type, or a **derived key per type** — an access token and a refresh token must never
     be usable in place of each other;
  2. the main parser uses `jwt.WithValidMethods(HS256)`, `jwt.WithExpirationRequired()`, `jwt.WithIssuer(...)`;
  3. `InitConfig` **fails to start** when `JWT_API_SECRET` < 32 bytes outside `ENVIRONMENT=local`;
  4. one fixed message + `data.code` (`TOKEN_EXPIRED`/`TOKEN_INVALID`), **not** the JWT library's text.

### 5.3 Per-request authentication (`AuthSessionUsecase.Authenticate`)

1. Empty `Authorization` → 401 `"Unauthorized, token is required."`.
2. JWT parse fails → 401 (`TOKEN_INVALID`/`TOKEN_EXPIRED`).
3. The account no longer exists → 401 `"Your session has ended. Please log in again."`.
4. The login's `password_timestamp` differs from the claim → 401 `"Password has been changed. Please log in again."` (a
   password change kills every old token in every account of that login).
5. A `PENDING_DELETION` account → 403 with the deletion state in `data` (checked before the session so the device knows
   why).
6. Roles: an owner whose login is not the account's owner → 401; a member whose membership is gone → 401
   `"You are no longer on this team."`; a member **never inherits the account's ADMIN role**.
7. Session revoked/expired/opened before `sessions_revoked_at`/not matching (login, account, member) → 401.

### 5.4 Session lifecycle

- **Sign-in** (every path) opens a new session per device: `{user, token, refresh_token, login, member}`.
- **Refresh** `POST /user/refresh-token {refresh_token}`: find the session by hash; check that it is alive + the
  membership; **rotate** (the old refresh token is spent, compare-and-set); two racing refreshes → the loser gets 401.
- **Logout** `POST /me/logout {refresh_tokens:[…]}`: no bearer, ≤ 50 tokens, an unknown token is not an error; the
  related access tokens die immediately.
- **Password change:** every other session of that login is revoked; the caller receives new tokens. **Password reset:**
  every session is revoked, one new session is opened.
- Cleanup of sessions expired/revoked > 7 days through a scheduled command (**actually schedule it** — a command that is
  only documented as "daily" never runs).

### 5.5 Client flow (standardized in the handoff)

- The client stores `token` + `refresh_token`. On a 401: **one** refresh (single-flight; other requests wait for the
  same result), then retry the request **once**. Refresh rejected → the session ends (open another stored account or the
  login page).
- 403 pending-deletion = a dedicated screen, not a toast.
- **MUST NOT** answer 401 for "logged in but not allowed" — a 401 triggers a pointless refresh. Use **403** +
  `data.code`.
- Token storage: web `localStorage` (with a strict CSP), mobile secure storage.

### 5.6 Passwords

- argon2 hash (encoded string).
- Rules for a new password (register, change, first password, reset, accepting an invitation): at least 8 code points,
  at most 100 bytes of UTF-8; not **personal** (dominated by the name/email/username, including after reversing leet);
  not **common** (blocklist of ±3,000 keys, `go:embed`); not a **pattern**. Sign-in does not check these rules; no forced
  rotation (NIST SP 800-63B).
- Response: 400 + `data.reason ∈ {short, long, personal, common, pattern}`; the client translates.
- **Client–server parity through shared test vectors** (thousands of cases); the server is never looser than the
  client.
- A rejection during reset/invitation acceptance rolls back its transaction (the link can still be used).

### 5.7 One-time tokens, codes, anti-enumeration

- **Link tokens:** 32 bytes of `crypto/rand`, base64url without padding; stored as sha256 hex; single use; a successful
  use revokes the account's other links; a new link does not kill old links (a late email still works).
- **Numeric codes:** 6 digits from `crypto/rand`; stored as `sha256("<user_uuid>:<code>")`; lifetime 10 minutes; 5 wrong
  guesses kill the code; one live code per account; resend ≥ 60 s apart and ≤ 5 per hour.
- **MUST NOT** fall back to a weak random source — `crypto/rand` fails = the request fails.
- **Anti-enumeration:** forgot-password is always 200 (unknown email or throttled); resending verification always
  succeeds; an account-deletion request is always 202; every code-verification rejection = one 400 with one message; an
  unknown / expired / used reset token = an identical message.
- **MUST (improvement)** login: **one message** for account does not exist / wrong password / account without a password,
  plus a throttle (§6.4).
- **(improvement)** one status per kind of failed link (not 400/401/403/410 depending on the feature) +
  `data.code`.

### 5.8 Purpose-bound tokens & derived keys

- Account-recovery token: JWT HS256 with a **derived key** `HMAC-SHA256(secret, "<app>/account-recovery/v1")`, a
  `purpose` claim, a 15-minute lifetime, `WithValidMethods` + `WithExpirationRequired`; the rejection reason is logged
  without the token.
- The version-labeled derived-key pattern for every purpose (wallet links, QR tokens, price quotes):
  `"<app>:<feature>:<purpose>:v1"`. An optional dedicated env to rotate one kind separately.

### 5.9 Social login

- **Apple:** verify the id token (JWKS cached for 12 hours, unknown `kid` → fetch again; `iss`; `aud` ∈ the registered
  client IDs (web Service ID + iOS bundle); `exp`; nonce). Accounts are looked up by `sub`, not by email. An existing
  account is linked only when the email is `email_verified` **and** not a private relay (anything else = an account
  takeover path). The `form_post` callback goes to a **backend** Return URL; the token is handed to the SPA through the
  **URL fragment** (`#token=…`) — it is not sent to the server and does not leak through `Referer`. Detach is rejected
  when the login has no password.
- **Google:** the `platform` field (`WEB` default, `IOS`, `ANDROID`) picks the client & redirect when exchanging the
  code. Linking an integration: a random 32-byte `state` in Redis for 10 minutes, bound to the account, single use
  (`GETDEL`), empty is rejected.
- **Never logged:** private keys, client secrets, authorization codes, identity tokens, provider request/response bodies.

### 5.10 Account status & multiple accounts

- Account status is checked at **every door** (middleware, refresh, every sign-in, the account switcher). The public page
  of an inactive account → 404 through the gate (the gate reads the primary, for accounts that were just recovered).
- `/me/accounts`: list of the login's accounts + memberships; `POST /me/accounts/{uuid}/session` opens a session without
  a password (someone else's account 403, nonexistent 404); a limit on the number of accounts per login (422).

### 5.11 Devices (machine auth)

Pairing with a 6-digit code valid for 10 minutes → the device stores a `machine_token` → subsequent requests send
`Authorization: Machine <token>`; revoke/re-pairing → 401; global pairing failures > 30/minute → 429.

---

## 6. Security

### 6.1 Ownership / IDOR

- **MUST** check ownership in the usecase ([01-architecture.md](01-architecture.md) §5.4) + writes carry the owner in
  `WHERE` (0 rows = 404).
- **MUST** maintain an **ownership audit table for every route** (`docs/reference/…`): Auth, identifiers from the
  client, where it is enforced, class `OK / MISSING / PUBLIC-BY-DESIGN / ADMIN / N/A`. Every new route adds one row.
- An identifier that belongs to someone else: in the **path** → 404; as a **foreign key in the body** → 400 with the same
  text for "does not exist" and "not yours" (`"Availability not found."`). A 403 for someone else's resource is a leak.
- **MUST** error `data` never contains another tenant's rows (incident: a 409 overlap on a public endpoint returned
  another customer's booking).
- **MUST** include the owner in cache keys and in search index queries.
- **MUST** privileged columns (role, account status) are never written by a generic update (a profile update that reads
  from the replica and then writes every field can restore an old role).
- **Object keys from the client:** only a file directly in the caller's folder, as minted at presign time; reject `/`,
  `\`, `..`, empty names; an old file is deleted only if it is in the caller's folder.
- A just-created foreign key is checked through the transaction (primary).
- **SHOULD** use a separate public DTO for public endpoints (not the same DTO with fields blanked out), without internal
  ids.

### 6.2 Team member access (many users per tenant)

| Declaration | Meaning |
|---|---|
| `Access(View(pages…), Edit(pages…))` | passes when the member has that level on any one of the pages (OR); two `access(...)` = AND |
| `OwnerOnly()` | account owner only |
| `AnyMember()` | every member |
| `PerLogin()` | belongs to the caller's login, whatever the account |
| `CheckedInHandler()` | the usecase checks it itself (per field/body) |

Access is read from the DB on every request (takes effect on the next request); no access → 403
`"You do not have access to this page."`. Shared routes use **per-field guards**: a meaningful field (not `null`, `""`,
`false`, `0`, `{}`, `[]`) needs extra permission; one forbidden field rejects the whole request before anything is
written.

### 6.3 Secrets & keys

- Production: secrets in SSM → task definition `secrets.valueFrom`; non-secret switches as plain env
  ([08-aws-infrastructure.md](08-aws-infrastructure.md) §3).
- **MUST (improvement):** only `.env.example` (placeholders) is committed; every other `.env*` is in `.gitignore`;
  **a secret scanner (gitleaks) in CI**. Never track developer env files such as `.env.local`/`.env.staging`.
- **MUST NOT** put credentials in code comments.
- **MUST** use one HMAC key per purpose (a dedicated env or a version-labeled derived key). A feature without a key → 503
  (masked) + a startup log that names the reason without the key's contents. **MUST NOT** use a random per-process key
  (other instances cannot verify).
- **MUST** `InitConfig` rejects env that redirects third-party endpoints (`*_BASE_URL`, `*_ENDPOINT` for test
  stand-ins) outside `ENVIRONMENT=local` — such env sends the owner's tokens to whatever host it names.

### 6.4 Rate limiting

- **MUST (improvement)** a per-IP **and** per-identity limiter for login, register, refresh, and public endpoints that
  write data; **SHOULD** add a rate-based rule in the Cloudflare WAF.
- Proven per-feature throttles:

| Feature | Limit | Stored in | Response |
|---|---|---|---|
| Forgot password | 1/60 s and 5/hour per account | Postgres (token rows) | silent 200 |
| Resend verification | 60 s and 5/hour | Postgres | silent success |
| Verification code | 5 wrong attempts kill the code; 10 minutes | Postgres | uniform 400 |
| Public code check (voucher) | 30 NOT_FOUND/minute per shop | Redis | 429 |
| Device pairing | 30 failures/minute globally | Redis | 429 |
| Public forms | resubmit ≥ 2 minutes apart | Postgres | 202 |

- Redis counter: key `<feature>:<scope>:<unix/window>`, `INCR` + `EXPIRE 2×window` in one `TxPipeline`, counted
  **before** the decision, decremented again with Lua when the attempt ends up not counting, **fail-open** when Redis is
  down ([04-caching.md](04-caching.md) §10).
- 429: `"Too many attempts. Please try again later."` + **(improvement)** a `Retry-After` header.

### 6.5 CORS

- An **explicit** allow-list (production & staging web, internal dashboard, alias domains, `http://localhost:5173` for
  dev/e2e), methods `GET,POST,HEAD,PUT,DELETE,PATCH,OPTIONS`, `ExposeHeaders: Content-Length,X-Trace-ID,Content-Disposition`,
  `MaxAge: 86400`, `AllowHeaders` including the client capability header. **Pinned by tests** (including fake origins
  such as `https://<alias>.example.org` that must be rejected).
- **(improvement)** the list comes from per-environment config (`localhost:5173` only outside production);
  `AllowCredentials: false` unless cookies are used; write origins without a trailing slash.
- CORS is **not** a security boundary for a bearer API — it only governs browsers.

### 6.6 Presigned URLs (R2)

- **Upload:** the server mints the key `<prefix>/<caller_uuid>/<sub>/<uuidv7>.<ext>` → the client `PUT`s directly (URL
  valid for 1 hour) → the client confirms the key to the owner's endpoint, which validates the folder.
  **MUST** the presigned PUT signs `ContentType` **and**
  `ContentLength` (R2 rejects any other type/size) and returns the `content_type` the client must send (`File.type` in
  the browser is often empty).
- **Reading private objects:** `ResponseChecksumValidation = WhenRequired` (only `host` is signed — `x-amz-checksum-mode`
  makes `<img>` get a 403; incident: KYC images broken for two months; a test asserts `X-Amz-SignedHeaders == host`);
  `ResponseContentType` from the extension + `ResponseContentDisposition: inline`; a 15-minute lifetime reported to the
  client + an endpoint to refresh the URL.
- **SHOULD** use a *windowed presigner*: the signing time is rounded down to the start of the window, `X-Amz-Expires` =
  2× the window → the URL stays the same for one window, so the browser can cache it.
- PII in a private bucket without a public host; public assets in a public bucket with a custom domain. **MUST NOT** log
  signed URLs. R2 details: [09-cloudflare.md](09-cloudflare.md) §4.

### 6.7 Incoming webhooks

| Aspect | Rule |
|---|---|
| Verification | signature (HMAC) **before** the body is parsed, `hmac.Equal` (constant-time), time window ±5 minutes |
| Path | from config/constants, exactly the one registered (the path that is signed is not the path Fiber sees behind a proxy) |
| Empty secret | **fail-closed**: 5xx (the provider retries) or 503 — **MUST NOT** fail open |
| Signature fails | 401; the body is **not** logged |
| Duplicate | 200 without doing the work (status CAS / `ON CONFLICT DO NOTHING`) |
| Unreadable payload | 400; the body is logged **masked**, only after the signature passes |
| Processing fails | 5xx → the provider retries |
| Unknown event | 200, ignored, metric |
| Body hash | canonical JSON (`UseNumber`, sorted keys, HTML escaping off) when the provider's scheme requires it |
| Amounts | float noise rounded to the smallest unit, real decimals rejected |
| Switch | **MUST NOT** put a feature switch in front of a webhook endpoint shared by several features |

### 6.8 Capability & signed links

Buyer/invitation tokens are stored as sha256 and compared with `subtle.ConstantTimeCompare`; a wrong token gets the same
answer as an unknown uuid (404). Signed links: HMAC over the id + `exp`, a short lifetime, `Cache-Control: no-store`.

### 6.9 Logs & sensitive data

- **MUST NOT log:** passwords, any token (access, refresh, reset, recovery, machine), verification codes, presigned URLs,
  private keys, client secrets, authorization codes, identity tokens.
- Masking: bank account numbers keep only the last 4 digits; money webhook bodies: keys containing `name`, `email`,
  `phone`, `address`, `account_number`, `va_number`, `card`, `nik`, `npwp`, `birth`, `description`, `note` are masked;
  bodies are cut at 64 KB.
- **SHOULD** log the login uuid after success, not the email. Fiber's access log records the path without the query — a
  token in the path gets recorded too (which is why tokens are not put in the path).
- The error tracker normalizes uuids, emails, IPs, and `ERR_…` when grouping ([06-observability.md](06-observability.md)).

### 6.10 Miscellaneous

- **(improvement)** `/swagger/*` turned off or protected in production.
- **MUST NOT** use HTTP helpers with `InsecureSkipVerify: true` or that log bodies. One outbound HTTP client per
  integration, with timeouts and TLS verification.
- Outbound calls carry the provider's idempotency key (`X-Idempotency-Key`, a derived merchant reference).
- **(improvement)** `Idempotency-Key` required for POSTs that move money.
- **(improvement)** CI runs `go test ./...` (including the architecture, route access, and error message tests) before
  deploy (not only locally).

---

## 7. Feature switches

```go
// config: one accessor per switch, read at request time (not when the route is registered)
cfg.Queue.Enabled = GetEnvBool("QUEUE_ENABLED", false)
func IsQueueEnabled() bool { return cfg.Queue.Enabled }

// route: the switch goes FIRST, before auth
queueFlag := middlewares.FeatureFlagMiddleware(config.IsQueueEnabled)
f.Get("/queue", queueFlag, oauthMiddleware, access(view(models.PAGE_QUEUE)), queueController.List)
```

- Off → `{"status_code":404,"status_message":"Failed","message":"This feature is not available yet."}` +
  **(improvement)** `data.code: "FEATURE_DISABLED"`; **one** middleware for every switch (one text, never a switch checked inside a
  usecase).
- Read at request time → tests can flip it; rollback = change the env + restart the task, no data change.
- **The switch turns off every effect of the feature:** routes 404, workers stay idle, the outbox is not filled.
- **Off by default**; turned on after every backend package is live and the clients are ready ("jangan pasang rute
  setengah jadi di production" (do not put half-finished routes in production)). The switch also guards steps that
  cannot be rolled back (e.g. creating multiple accounts).
- Guards that depend on a feature (e.g. subscriptions) become pass-through while the feature is off, but stay listed on
  the route.
- Staged validation switches `off|log|enforce`: **(improvement)** an empty value = `off`/`log` or fail to start — never
  `enforce` (it once closed all of `/admin/*` with a 503 when the deploy went out before the env).
- The switch inventory (env, default, effect when off) is maintained in the project's platform doc and in the tfvars
  comments.

### 7.1 Client side

Clients tell a "router 404" (the route does not exist yet → preview/dummy mode) apart from a real JSON 404, and recognize
a switch 404 by `data.code`. That way a client can release first with dummy data and move to the real endpoint on its own
as soon as the router stops answering 404.

---

## 8. Time & time zones in the API

### 8.1 Formats

| Kind | Format | Example |
|---|---|---|
| Schedule instants (booking, slot) | unix seconds `int64` | `"start_time": 1672531200` |
| Record timestamps (`*_at`) | RFC 3339 UTC | `"2026-10-15T03:04:05Z"` |
| Calendar dates | `"YYYY-MM-DD"` in the owner's zone | `start_date` |
| Zones | IANA name | `"Asia/Makassar"` |

**(improvement)** fix the format per field-name suffix from the start (`*_at` always RFC 3339 UTC; schedule instants
always one format) and write it into the API conventions (never unix in one place and RFC 3339 in another for the same suffix).

### 8.2 Zone model

| Who/what | Zone | How it changes |
|---|---|---|
| Personal account | device zone | every session reports the device zone (`PUT /user/timezone/device`); the account moves when "follow device" is on |
| Business account | fixed | owner only, with `confirm: true` (opening hours shift along) |
| Team member | business zone | cannot be changed by the member |
| A booking's customer | `customer_timezone` | chosen on the booking page; defaults to the account zone |
| Booking rules (lead time, window, per-day limit) | provider's calendar | — |

### 8.3 Server rules

- One zone validator (`CanonicalTimezone`): reject `""`, `"Local"`, abbreviations (`EST`), POSIX; rename old names to
  new ones (`Asia/Calcutta` → `Asia/Kolkata`). Default to the account zone when empty/unknown.
- Offset & abbreviation are **derived by the server**; values sent by the client are ignored.
- "Today", lead time, the reservation window, and per-day limits are computed in the **provider's calendar**; the
  customer's zone is only for grouping slots under their dates. Wall-clock times are built with `time.Date` on the
  owner's date (DST-safe).
- Admin date filters `YYYY-MM-DD` are read as dates in the platform's business zone → a half-open UTC range.
- Notifications are rendered in the recipient's zone (the customer in their booking's zone, the host & team in the
  account zone at send time).

### 8.4 Contract

- The zone object in account responses:
  `"timezone": {"location":"Asia/Makassar","offset":"+08:00","abbreviation":"WITA","label":"(UTC+08:00) Asia/Makassar","auto":true}`.
- `PUT /user/timezone/device {location}` → 200 for any JSON body: `{applied, reason, timezone}`, `reason ∈ {applied,
  same, manual, business, invalid}` — **the server decides**.
- A business account's zone changes only with `confirm: true`; without it the `timezone` key is ignored (old clients do
  not shift the opening hours). An unknown zone in a change that applies → 422 `"Invalid timezone."`.
- `GET /timezones`: a sorted list with `aliases` per zone.

---

## 9. Admin endpoints

- **Chain:** `oauthMiddleware` + owner-only; team members never pass. **(improvement)** one `AdminOnly()` middleware in
  the route chain, pinned by an AST test like the access declarations, answering **403** + `data.code: "ADMIN_ONLY"`
  (not checks scattered across validators, 401, and different texts).
- The role is checked **before** any input is read, **fail-closed** (no session, another `Locals` type, NULL role =
  rejected); the role is read from the DB on every request (a revoked admin is rejected immediately even though the
  token still claims ADMIN).
- One definition of admin: `User.IsAdmin()` = role exactly `"ADMIN"`.
- **Changing a role** (`PATCH /admin/users/{user_uuid}/role {"role":"ADMIN"|"USER"}`): one transaction that starts with
  `pg_advisory_xact_lock(hashtext('users:role'))` (one lock for every role change — its invariants read other rows);
  re-read under the lock through the transaction (is the caller still an admin? does the target exist?); 409 invariants
  (already in the target role, revoking yourself, revoking the last admin); write order: audit row → index outbox →
  `UPDATE users SET role` → cache refresh last of all; a failure anywhere → roll everything back.
- **Audit trail:** an append-only table without FKs (`user_role_changes(user_uuid, previous_role, new_role,
  changed_by_uuid, created_at)`); manual changes through SQL follow a runbook with the same lock and
  `changed_by_uuid = 'SQL'`; admin actions that move money/grant access write an audit log row after they succeed;
  sensitive events are emailed to the other admins.
- **Admins read tenant data** through the seller usecase with the target account as the owner (exactly the rows the
  seller sees; e2e compares the bodies byte for byte). The target account is checked to exist first (404); the
  platform's pseudo-owner must not be readable as a user.
- **Forced actions** (force delete): preview first (`GET …/deletion`), then the action; an admin account cannot be
  deleted that way (403). Actions that read a provider: 424 when the provider cannot be read, "Nothing was changed.", an
  audit row.

---

## 10. Client handoff

### 10.1 Swagger (swaggo)

- `make gen-swagger` = `swag fmt && swag init -g ./app/cmd/main.go -o ./app/specs` → `docs.go`, `swagger.json`,
  `swagger.yaml` are committed.
- `.swaggo` replaces types for the documentation: `null.String → string`, `null.Int → int64`, `null.Bool → bool`,
  `redifu.Record → responses.RecordResponse`.
- `main` annotation: `@securityDefinitions.apikey BearerToken` (`Authorization` header).
- Controller annotation template:
  ```go
  // ChangeRole godoc
  //
  //	@Summary		Make an account an admin, or remove its admin access
  //	@Description	<full contract: rules, every status and its exact message text, check order, switches, cache headers>
  //	@ID				admin-change-user-role
  //	@Tags			Admin
  //	@Security		BearerToken
  //	@Accept			json
  //	@Produce		json
  //	@Param			user_uuid	path		string								true	"Target user UUID"
  //	@Param			body		body		requests.AdminUserChangeRoleRequest	true	"The new role: ADMIN or USER"
  //	@Success		200			{object}	swagger_models.SuccessResponse{data=responses.AdminUserRoleChangeResponse}
  //	@Failure		400			{object}	swagger_models.BadRequestResponse
  //	@Failure		401			{object}	swagger_models.UnauthorizedResponse
  //	@Failure		404			{object}	swagger_models.NotFoundResponse
  //	@Failure		409			{object}	swagger_models.ConflictResponse
  //	@Failure		500			{object}	swagger_models.InternalServerErrorResponse
  //	@Router			/admin/users/{user_uuid}/role [patch]
  ```
- **A multi-line `@Description` holds the whole contract** (exact error texts, check order, switch behavior,
  `Cache-Control`) — this is what makes Swagger useful as a contract. The Swagger envelope models are derived from the
  same envelope struct (do not let the documentation models go stale).

### 10.2 Postman (required, manual)

`app/specs/<App>.postman_collection.json` (schema v2.1): one folder per route group + a `Public` subfolder; variables
`{{BASE_URL}}`, `{{ACCESS_TOKEN}}`; bearer auth per request, explicit `noauth` for public ones; path variables with example
values; query params with a `description`; the request `description` holds the contract & JSON examples; request names
are sentences (+ a package marker). The handoff names the relevant folders and requests.

### 10.3 Briefs, handoffs, client guides

- Briefs from FE (`docs/requirements/BACKEND_*.md`, the sender's file name is kept; structure: Summary, Rules, Data,
  Endpoints, Responses & email, Team access, Tests, What FE does after BE is live, Open decisions). **The backend does not
  edit the brief's contents** — deviations are written as a **"Backend revisions" (R1…Rn)** block above the brief.
- The handoff (`docs/handoffs/<feature>-frontend-prompt.md`) is self-contained and declares itself authoritative ("the
  final contract is below; where they differ, this document wins"). Structure:
  ```markdown
  # Prompt: <Feature> — <Web & Flutter | Dashboard>
  > To hand to the <repo> agent/team. §1–§4 for everyone; §5 Web, §6 Flutter.
  > - Backend: branch/commit; status (live since … / hand over after deploy); migrations; switch (default off)
  > - Check the backend is deployed: `GET /x` answers 200, not a route 404
  > - Base `{{BASE_URL}}` · Auth · New endpoints · Postman folder · Swagger · References (brief, plan, reference)
  > - Verified against <repo>@<sha> (date)
  ## Working rules (for agents: language, worktree/branch, do not touch production, ask before pushing)
  ## User decisions (quote + date)
  ## Current state (file:line in the client repo)
  ## 0. Rules that apply everywhere (envelope, switch 404, time format, polling, masking)
  ## 1..n Contract per screen (request, response JSON, error table: status + message + data.code, error order)
  ## UX contract (what may / may not be shown)
  ## Web: files changed · Flutter: model / API / repository / bloc
  ## Error translations (English message → UI text)
  ## Test (required) · Local E2E (required) · Test checklist
  ## Out of scope
  ## Done means
  ```
  Recurring content patterns: behavior when data changes mid-scroll, what happens to old clients, "do not call endpoint X
  for Y", polling frequency, the full list of enum values. Template: [templates/docs/handoff-frontend-prompt.md](../templates/docs/handoff-frontend-prompt.md).
- Client integration guides (`docs/reference/frontend/`) open with "This document is the **contract**" and contain
  numbered flows, steps per endpoint, **"what must be shown / what must not"**, error handling per status, and an
  endpoint summary table.
- Release: backend first, until it is live; clients check that the backend is deployed (the new endpoint answers 200, not
  a route 404); the web & mobile message translation tables are updated at the same time.

---

## 11. Per-endpoint security checklist

For every new or changed endpoint:

1. **Route:** name & method per §2.2; static before parameterized (proven by a test); feature switch first when it is a
   new feature.
2. **Public or not:** public → a reason in the audit table, the active-account gate, a minimal public DTO; not public →
   auth + access declaration, or `AdminOnly`.
3. **Admin:** role checked before input is read, fail-closed; not allowed → 403 + `code`.
4. **Identity:** from `Locals` **after** parsing; identity fields `json:"-" query:"-" form:"-"`; key guards use
   `EqualFold`.
5. **Every identifier from the client** (path, query, body, FK, object key, cursor) is resolved inside the caller's
   scope; "does not exist" = "not yours" (404 in the path, 400 for a body FK, same text).
6. **Writes carry the owner in `WHERE`**; 0 rows = 404; privileged columns are not written by generic updates.
7. **Responses & error `data`** without other tenants' rows, personal contacts, unnecessary internal ids, tokens, or
   long-lived signed URLs.
8. **Input is bounded:** text length, list size, `per_page`, date range length, enums; parse errors = a fixed message.
9. **Messages:** 4xx = English sentinel + `data.code`; no driver/library/provider text; 5xx masked + `error_id`.
10. **Abuse:** throttle/429 for login, public endpoints that write, and secret checks; anti-enumeration for flows gated
    by an email/code.
11. **Secrets & tokens:** through the body/header, not the path; stored hashed, compared in constant time; TTL, single
    use; one HMAC key per purpose; a feature without a key → 503.
12. **Files:** the key is minted by the server in the caller's folder; the presigned PUT signs type & size; the
    confirmation validates the folder; a private bucket for PII; GET signs only `host`, with a TTL; URLs are not logged.
13. **Webhooks:** verify before parsing, constant-time, time window; path from config; fail-closed without a secret;
    idempotent (2xx for duplicates); body logs masked and only after the signature passes.
14. **Logs:** no credentials; PII masked; `trace_id` on every line; audit rows for privileged actions.
15. **Cache:** keys include the owner; credentials never go into Redis; the right `Cache-Control`.
16. **Concurrency:** a lock or compare-and-set for invariants (money, roles, schedules); `Idempotency-Key` for money
    POSTs.
17. **Docs:** Swagger (full contract), Postman, CHANGELOG, `reference/`, handoff, audit table row.

## 12. Definition of done for an endpoint

1. Tests: usecase (including another account → rejected, nothing written; and the legitimate owner), validator (every
   spelling of the identity keys), route (order, access declaration), e2e when it crosses layers.
2. `make gen-swagger` output committed; the annotations hold the full contract.
3. Postman request with example body & params.
4. CHANGELOG entry.
5. `docs/reference/...` updated; ownership audit table row added.
6. Handoff prompt when a client needs to change.
7. Migrations and switches recorded (switches default off).
8. `TestArchitecture`, `TestErrorLogCalls`, route access tests green.
