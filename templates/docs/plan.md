# Plan: <title>

> **Status (<date>, <morning/afternoon/evening>):** **<not started | in progress | done on the branch | done and live
> in production>.** <P1–Pn on branch `<b>` (`<sha>`); PR #N; migration NNN run <when> with user approval; …>.
> Details in [§10](#10-implementation-status).
>
> - **Fulfills:** `docs/requirements/<BRIEF>.md` (§…)
> - **Checked against:** BE `origin/master` `<sha>` (last migration NNN); web `<branch>` `<sha>`; mobile `<sha>`;
>   the relevant production state (e.g. `GET /x` 404)
> - **References:** `docs/reference/<…>.md`, related runbooks

## 1. In short

<2–5 sentences: the problem, the change, who is affected.>

## 2. What changes

| Endpoint / component | Before | After |
|---|---|---|
| `POST /widget` | … | … |

## 3. Decisions

| # | Decision | Reason |
|---|---|---|
| K1 | … | … |

## 4. Work packages

| Package | Contents | Migration | Switch |
|---|---|---|---|
| P1 | … | `NNN_x.sql` (additive, before deploy) | `WIDGET_ENABLED` (off at deploy) |
| Pn | Release to production | | |

## 5. Tests

| ID | Case | Expected | Test |
|---|---|---|---|
| T1 | … | 200, … | `TestWidget/T1 …` |
| T2 | resource owned by another account | 404, nothing written | `TestWidget/T2 …` |

## 6. Work and release order

1. Pre-deploy migration …
2. BE …
3. Clients …
4. Switch …

## 7. Risks

## 8. Outside this plan

## 9. Done means

- [ ] Every §5 case has an e2e that fails on master and passes on the branch
- [ ] Full regression: no new FAIL
- [ ] Swagger + Postman + CHANGELOG + reference + handoff updated

## 10. Implementation status

| Package | Status | Commit |
|---|---|---|
| P1 | | |

**What was proven:** …
**Release:** …
