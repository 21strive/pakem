# Prompt: <Feature> — <Web & Flutter | Dashboard>

> To be **handed to the <client repo> agent/team** (<stack>). §1–§4 are for everyone; §5 is Web only, §6 Flutter only.
>
> - **Backend:** branch/commit `<sha>` on `master`; status: live since <date> | hand over after deploy. Migration
>   `<NNN_*.sql>`; switch `<FEATURE>_ENABLED` (off by default; turned on after the clients release).
> - **Check that the backend is deployed:** `GET /<x>` answers 200 (not a route 404 / not a `FEATURE_DISABLED` 404).
> - **Base:** `{{BASE_URL}}` · **Auth:** `Authorization: Bearer <token>` | no auth | `Machine <token>`
> - **New endpoints:** `POST /widgets`, `GET /widgets?cursor=`, …
> - **Postman:** folder `<x>` → `<request name>` · **Swagger:** `app/specs/swagger.json`
> - **References:** brief `docs/requirements/<BRIEF>.md` (+ Backend revisions), plan `docs/plans/<x>.md`, `docs/reference/<y>.md`
> - Verified against `<repo>@<sha>` (<date>).
>
> The final contract is below; wherever it differs from the brief, **this document prevails**.
> Copy everything below the line as the prompt — it is self-contained.

---

## Working rules (for the agent)

- Language: replies to the user in the user's language; code, commits, and docs in English; UI text in the product's language.
- Worktree + new branch from the client repo's main branch; do not touch production; ask before push/merge.

## User decisions

- "<quote>" (<date>)

## Current state

- <related file:line in the client repo>

## 0. Rules that apply everywhere

- Envelope: `{status_code, status_message, message?, error_id?, data?, pagination?}`; 5xx = `"Internal server error"` +
  `error_id` (show the `error_id` for reporting).
- Switch 404: `data.code = "FEATURE_DISABLED"` → hide the feature; route 404 (not JSON) → backend not deployed yet.
- Time: `*_at` RFC 3339 UTC; schedule instants as unix seconds; dates `YYYY-MM-DD` in the owner's time zone.
- Paginated lists: `{<items>, next_cursor, has_more}`; opaque cursor; invalid cursor → 400 → reload from the start.
- 401 → one refresh (single-flight), then retry once; 403 = not permitted (do not refresh).

## 1. The mental model — read this first

<Core concepts in the client's terms: what the server stores, what the client computes, what must NOT be assumed.>

## 2. The pitfalls easiest to get wrong

- <behavior when data changes mid-scroll>
- <what happens to old clients>
- <"do not call endpoint X for Y">

## 3. Contract per screen

### 3.1 `POST /widgets`

Request:

```json
{ "name": "Widget A", "price": 150000 }
```

Response 201:

```json
{"status_code":201,"status_message":"Success","data":{"widget_uuid":"0d3c5a52-7d0e-4c1b-9a43-2f3c9d6c1e11"}}
```

Errors (exact messages — for the client's translation table), in the order the server checks them:

| Status | `message` | `data.code` | When |
|---|---|---|---|
| 400 | `name is required` | — | empty field |
| 404 | `Widget not found.` | — | does not exist **or** not the caller's |
| 409 | `widget name already exists` | `DUPLICATE_NAME` | name used by another widget of the account |

## 4. UX contract

- What must be shown: …
- What must not be shown: …
- Polling: <frequency> · Full enum: `ACTIVE`, `ARCHIVED`

## 5. Web — files to change

## 6. Flutter — model / API / repository / bloc

## 7. Error translation (English message → UI text)

| API message | UI text |
|---|---|
| `widget name already exists` | "Nama sudah dipakai." ("Name is already taken.") |

## 8. Tests (required) · Local E2E (required) · Test checklist

- Unit/widget tests, lint/analyze no worse than the baseline.
- E2E against the local backend (Vite on `localhost:5173` for CORS); screenshots.

## 9. Out of scope

## 10. Done means

- [ ] Every §3 screen uses the contract above
- [ ] Translation table updated
- [ ] Tests + local E2E pass, screenshots attached
