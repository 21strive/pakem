-- Migration: NNN_<what>.sql
-- <Source feature / plan / brief> (docs/plans/<x>.md, docs/requirements/<BRIEF>.md §n)
--
--   widgets.archived_at   timestamptz NULL — when the owner archived the widget; NULL = active. Written only by
--                          WidgetArchiveUsecase (a dedicated statement, not the generic Update).
--
-- Why: <the problem it solves; the incident, if any>
-- Deploy order: BEFORE the code — the new binary names this column in a SELECT (no migration = 500); the old binary
--               does not read/write it (additive).
-- Locks/rewrite: ADD COLUMN nullable = metadata-only, brief ACCESS EXCLUSIVE (lock_timeout 5s).
-- Before applying: (no pre-check) | <query that finds the violating rows>
-- How to run: psql "<dsn session :5432>" -X -v ON_ERROR_STOP=1 -f migrations/NNN_<what>.sql
-- Rollback: ALTER TABLE widgets DROP COLUMN IF EXISTS archived_at;  (destructive — user approval; only before the code uses it)
-- Backfill: none | backfills/<x>.sql after deploy
-- Additive only. Idempotent: every statement can run twice.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- New table: uuid + randid + owner + timestamptz NOT NULL DEFAULT now()
CREATE TABLE IF NOT EXISTS widgets (
    uuid        uuid         PRIMARY KEY,
    randid      varchar(16)  NOT NULL,
    user_uuid   uuid         NOT NULL,
    name        varchar(120) NOT NULL,
    status      varchar(20)  NOT NULL DEFAULT 'ACTIVE',
    price       bigint       NOT NULL DEFAULT 0,          -- whole rupiah (whole units of the project's currency)
    settings    jsonb        NOT NULL DEFAULT '{}'::jsonb,
    sort        integer      NOT NULL DEFAULT 0,
    deleted_at  timestamptz  NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT widgets_status_check   CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    CONSTRAINT widgets_price_check    CHECK (price >= 0),
    CONSTRAINT widgets_settings_check CHECK (jsonb_typeof(settings) = 'object')
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_widgets_randid ON widgets (randid);
-- unique name per owner, case-insensitive, only for rows not yet deleted
CREATE UNIQUE INDEX IF NOT EXISTS uq_widgets_user_name ON widgets (user_uuid, lower(name)) WHERE deleted_at IS NULL;
-- the owner's list (new table, no writes yet → a plain index inside the transaction is safe)
CREATE INDEX IF NOT EXISTS idx_widgets_user_sort ON widgets (user_uuid, sort) WHERE deleted_at IS NULL;

COMMENT ON COLUMN widgets.price IS 'Price in whole rupiah (bigint). Never float.';

-- New column on an existing table: nullable / constant default (metadata-only)
ALTER TABLE widgets ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;

-- Constraint on a table that already holds data: NOT VALID, validated once clean
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'widgets'::regclass AND conname = 'widgets_archived_status_check') THEN
    ALTER TABLE widgets ADD CONSTRAINT widgets_archived_status_check
      CHECK ((status = 'ARCHIVED') = (archived_at IS NOT NULL)) NOT VALID;
  END IF;
END $$;
ALTER TABLE widgets VALIDATE CONSTRAINT widgets_archived_status_check;

-- (optional) record this migration — see docs/02-database.md §2
-- INSERT INTO schema_migrations (version, sha256, applied_by) VALUES ('NNN_<what>', '<file sha256>', current_user)
-- ON CONFLICT (version) DO NOTHING;

-- Postcondition guard: roll back everything if the result is not as expected
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'widgets' AND column_name = 'archived_at') THEN
    RAISE EXCEPTION 'widgets.archived_at missing after migration';
  END IF;
END $$;

COMMIT;

-- Index on a LIVE table that is already busy: a separate file, no BEGIN/COMMIT, CONCURRENTLY + check indisvalid
-- (see docs/02-database.md §4.6).
