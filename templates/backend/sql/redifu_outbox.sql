-- Template — migrations/NNN_redifu_outbox.sql (the first redifu cache migration).
-- Run BEFORE the binary that reads the cache. One transaction; idempotent.
-- See docs/04-caching.md §3.

BEGIN;
SET LOCAL lock_timeout = '5s';

-- Change queue: one row per changed row in a watched table,
-- written by the trigger IN THE WRITER'S TRANSACTION. The drain deletes them (DELETE … RETURNING).
CREATE TABLE IF NOT EXISTS redifu_outbox (
    id         bigserial   PRIMARY KEY,
    owner_uuid text        NOT NULL DEFAULT '',   -- queue and lock partition; '' = global
    table_name text        NOT NULL,
    row_key    text        NOT NULL,              -- the row's key column (junction: its parent's key)
    op         text        NOT NULL,              -- INSERT / UPDATE / DELETE
    old_row    jsonb,                             -- the row before the change (NULL for INSERT)
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS redifu_outbox_owner_id ON redifu_outbox (owner_uuid, id);

-- A row's owner: its own column, '' (global), or the owner column of the parent row.
--   spec = '<column>' | '' | 'parent:<parent table>:<fk column>:<parent owner column>'
CREATE OR REPLACE FUNCTION redifu_owner_of(spec text, data jsonb) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    parts    text[];
    key_type text;
    found    text;
BEGIN
    IF spec IS NULL OR spec = '' OR data IS NULL THEN
        RETURN '';
    END IF;
    IF left(spec, 7) = 'parent:' THEN
        parts := string_to_array(spec, ':');
        IF data ->> parts[3] IS NULL THEN
            RETURN '';
        END IF;
        SELECT format_type(a.atttypid, a.atttypmod) INTO key_type
          FROM pg_attribute a
         WHERE a.attrelid = parts[2]::regclass AND a.attname = 'uuid' AND NOT a.attisdropped;
        EXECUTE format('SELECT %I::text FROM %I WHERE uuid = $1::%s', parts[4], parts[2], key_type)
           INTO found USING data ->> parts[3];
        RETURN COALESCE(found, '');
    END IF;
    RETURN COALESCE(data ->> spec, '');
END
$$;

-- AFTER INSERT OR UPDATE OR DELETE, FOR EACH ROW. TG_ARGV[0] = key column, TG_ARGV[1] = owner spec.
-- An UPDATE that changes nothing is not recorded; an UPDATE that moves the owner is recorded for both owners.
CREATE OR REPLACE FUNCTION redifu_capture() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    new_data  jsonb;
    old_data  jsonb;
    owner_new text;
    owner_old text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        new_data := NULL;
    ELSE
        new_data := to_jsonb(NEW);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        old_data := to_jsonb(OLD);
    END IF;
    IF TG_OP = 'UPDATE' AND old_data = new_data THEN
        RETURN NULL;
    END IF;

    owner_new := redifu_owner_of(TG_ARGV[1], COALESCE(new_data, old_data));
    INSERT INTO redifu_outbox (owner_uuid, table_name, row_key, op, old_row)
    VALUES (owner_new, TG_TABLE_NAME, COALESCE(new_data, old_data) ->> TG_ARGV[0], TG_OP, old_data);

    IF TG_OP = 'UPDATE' THEN
        owner_old := redifu_owner_of(TG_ARGV[1], old_data);
        IF owner_old IS DISTINCT FROM owner_new THEN
            INSERT INTO redifu_outbox (owner_uuid, table_name, row_key, op, old_row)
            VALUES (owner_old, TG_TABLE_NAME, old_data ->> TG_ARGV[0], TG_OP, old_data);
        END IF;
    END IF;
    RETURN NULL;
END
$$;

-- Installs (or reinstalls) a table's one and only redifu_capture trigger. Idempotent.
-- Every migration that watches the same table MUST use exactly the same arguments.
CREATE OR REPLACE FUNCTION redifu_watch(target regclass, key_column text, owner_spec text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = target AND tgname = 'redifu_capture') THEN
        EXECUTE format('DROP TRIGGER redifu_capture ON %s', target);
    END IF;
    EXECUTE format(
        'CREATE TRIGGER redifu_capture AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION redifu_capture(%L, %L)',
        target, key_column, owner_spec);
END
$$;

-- Removes every trigger (rollback to a binary without the cache). Afterwards: TRUNCATE redifu_outbox;
-- and before the cache is switched on again: command redifu-purge.
CREATE OR REPLACE FUNCTION redifu_unwatch_all() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    t record;
    n integer := 0;
BEGIN
    FOR t IN SELECT tgrelid::regclass AS rel FROM pg_trigger WHERE tgname = 'redifu_capture' LOOP
        EXECUTE format('DROP TRIGGER redifu_capture ON %s', t.rel);
        n := n + 1;
    END LOOP;
    RETURN n;
END
$$;

-- First set: the tables read by the cached views (example — adjust).
SELECT redifu_watch('users', 'uuid', 'uuid');            -- an account is its own owner
SELECT redifu_watch('widgets', 'uuid', 'user_uuid');
SELECT redifu_watch('widget_tags', 'widget_uuid', 'parent:widgets:widget_uuid:user_uuid');
COMMIT;
