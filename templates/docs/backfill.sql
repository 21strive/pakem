-- backfills/<what>.sql
--
-- What:  <what gets filled, for which rows>
-- When:  after migration NNN_<x>.sql (and deploy <sha>, if the new code must already be writing this column)
-- Why:   <reason>
-- Queue: <the worker that drains the outbox filled here, e.g. search-indexer>
-- Idempotent: safe to re-run (NOT EXISTS / ON CONFLICT DO NOTHING).
-- Run: psql -X -v ON_ERROR_STOP=1 -f backfills/<what>.sql   (session pooler :5432)

INSERT INTO search_index_outbox (entity_type, entity_uuid, operation, status)
SELECT 'widget', w.uuid, 'UPSERT', 'PENDING'
FROM widgets w
WHERE w.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM search_index_outbox o
    WHERE o.entity_type = 'widget' AND o.entity_uuid = w.uuid AND o.status = 'PENDING'
  );

-- Verify (the count still waiting for the worker; must drop to 0):
-- SELECT count(*) FROM search_index_outbox WHERE entity_type = 'widget' AND status = 'PENDING';
