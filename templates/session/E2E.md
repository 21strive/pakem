# E2E — <feature> (<slug>), <date>

Branches: BE `<b>` (includes origin/master `<sha>`), web `<b>` (includes main `<sha>`), mobile `<b>` (…).

## BE

| Check | Result |
|---|---|
| Unit tests | FAIL set = master's N (list: `run/unit-failset.txt`), none new |
| Architecture + error-message + route-access tests | pass |
| New e2e `scripts/e2e/<x>_test.go` (`TestX`) | N/N pass on branch; with master binary they fail at <step> |
| Full suite master vs branch | master RUN/PASS/FAIL/SKIP = …; branch = …; FAIL only on branch: 0; FAIL only on master = the new tests |
| Migrations on prod-dump copy | NNN in 0.05 s, idempotent on re-run, rows affected … |

## Web
vitest …; eslint/prettier …; build …; Playwright N/N — screenshot: `e2e/<…>.png`

## Mobile
analyze = baseline (N issues); test FAIL set = develop; e2e against the local BE …

## Notes
FAILs shared by both binaries and their cause (env, features without credentials, etc.).
