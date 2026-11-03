# Release — <feature> (<slug>)

> **Status:** NOT YET EXECUTED | EXECUTED <UTC> with user approval ("<quote>")

Branch / PR: … · Contents: … · Impact: …

| # | Step | Exact command | Correct output | If it fails |
|---|---|---|---|---|
| 0 | Merge `--no-ff` into master (tree = the tested tree) | `git merge --no-ff feat/<x> -F msg.txt` | | |
| 1 | Read-only pre-check | `psql … -c '\d widgets'` | column does not exist yet | stop |
| 2 | Backup | `pg_dump -Fc … > ~/backup/…_preNNN.dump` | file > 0 B | stop |
| 3 | Pre-deploy migration | `psql -X -v ON_ERROR_STOP=1 -f migrations/NNN_x.sql` | `CREATE TABLE` … | rollback §6 |
| 4 | Deploy BE | the project's deploy command (e.g. `gh workflow run deploy.yml --ref master` → `gh run watch <id> --exit-status`) | success; running digest = tag digest | circuit breaker; fix-forward |
| 5 | Verify | probe, logs, smoke test on a test account | … | |
| 6 | Clients | push web `main`; mobile `develop` | the static host's deploy check succeeds | |
| 7 | Switch | infra `WIDGET_ENABLED = "true"` | route 200 | set `"false"` |

## Rollback
…
