# <Procedure title>

**Written:** <date> · plan [`<x>.md`](../../plans/<x>.md) §n · **Migration:** `NNN_x.sql` · <idempotent / not idempotent>

> ### Why the order must not be reversed
>
> | | Old data | New data |
> |---|---|---|
> | Old code | … | … |
> | New code | … | … |

## Rules for running one

- One short psql connection through the session pooler :5432; `SET lock_timeout = '5s'`.
- Back up first: `pg_dump -Fc … > ~/backup/<db>_<YYYYMMDD_HHMM>_preNNN.dump` (mode 600).

## <Instance>

### Before (read-only)

```sql
-- count the affected rows, EXPLAIN the heavy queries
```

### Run

```bash
psql -X -v ON_ERROR_STOP=1 -f <file>
```

Correct output:

```
BEGIN
UPDATE 15
COMMIT
```

### Verify

### If it failed

### Rollback
