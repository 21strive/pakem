-- Template — notification outbox table (snapshot) + deliveries per channel × recipient.
-- See docs/05-workers-and-integrations.md §2–§3.
-- The project conventions (docs/02-database.md §1) still apply: add randid if the table is read through a model.

BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS notification_outbox (
    uuid              uuid PRIMARY KEY,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    notification_type varchar(100) NOT NULL,          -- key into the catalog in code
    dedupe_key        text UNIQUE,                    -- idempotency layer 1: TYPE:<entity>:<audience>:<recipient>[:discriminator]
    recipient_type    varchar(20)  NOT NULL,          -- audience
    recipient_uuid    uuid         NOT NULL,
    payload           jsonb        NOT NULL DEFAULT '{}'::jsonb,   -- snapshot at event time
    channel_override  text[],
    status            varchar(20)  NOT NULL DEFAULT 'PENDING',
    available_at      timestamptz  NOT NULL DEFAULT now(),         -- scheduled send time
    attempts          int          NOT NULL DEFAULT 0,             -- EXPAND-phase retries
    next_retry_at     timestamptz,
    last_error        text,
    locked_at         timestamptz,                                 -- claim; harvested by the reaper
    dispatched_at     timestamptz,
    group_key         text,                                        -- '<entity>:<uuid>' for bulk Cancel
    trace_id          varchar(100),                                -- originating request
    CONSTRAINT notification_outbox_status_check
        CHECK (status IN ('PENDING','PROCESSING','DISPATCHED','SKIPPED','FAILED','CANCELLED')),
    CONSTRAINT notification_outbox_payload_check CHECK (jsonb_typeof(payload) = 'object')
);
CREATE INDEX IF NOT EXISTS idx_notification_outbox_status_available ON notification_outbox (status, available_at);
CREATE INDEX IF NOT EXISTS idx_notification_outbox_group_pending ON notification_outbox (group_key) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_notification_outbox_status_updated ON notification_outbox (status, updated_at);

CREATE TABLE IF NOT EXISTS notification_delivery (
    uuid                  uuid PRIMARY KEY,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    notification_uuid     uuid NOT NULL REFERENCES notification_outbox (uuid) ON DELETE CASCADE,
    channel               varchar(20) NOT NULL,                    -- EMAIL | PUSH | WHATSAPP | IN_APP
    recipient_member_uuid uuid,                                    -- fan-out to team members (NULL = owner)
    address               text,
    status                varchar(20) NOT NULL DEFAULT 'PENDING',
    attempts              int NOT NULL DEFAULT 0,
    next_retry_at         timestamptz,
    locked_at             timestamptz,
    last_error            text,
    last_error_kind       varchar(20),                             -- RETRYABLE | PERMANENT
    skip_reason           varchar(30),                             -- NO_ADDRESS | OPTED_OUT | CHANNEL_DISABLED | NO_CHANNEL | …
    template_key          varchar(150),
    template_version      varchar(64),                             -- hash of the template content at render time
    idempotency_key       text NOT NULL UNIQUE,                    -- = delivery uuid (layer 3), passed to the provider
    provider              varchar(50),
    provider_message_id   text,
    sent_at               timestamptz,
    CONSTRAINT notification_delivery_status_check
        CHECK (status IN ('PENDING','PROCESSING','SENT','FAILED','SKIPPED','CANCELLED'))
);
-- layer 2: a repeated expand does not create duplicate deliveries
CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_delivery_target
    ON notification_delivery (notification_uuid, channel, (COALESCE(recipient_member_uuid::text, '')));
CREATE INDEX IF NOT EXISTS idx_notification_delivery_status_retry ON notification_delivery (status, next_retry_at);
CREATE INDEX IF NOT EXISTS idx_notification_delivery_channel_status_retry ON notification_delivery (channel, status, next_retry_at);
CREATE INDEX IF NOT EXISTS idx_notification_delivery_status_updated ON notification_delivery (status, updated_at);

COMMIT;

-- SIGNAL queue (search index / projection), minimal shape:
--   CREATE TABLE search_index_outbox (
--     id bigserial PRIMARY KEY, entity_type varchar(50) NOT NULL, entity_uuid uuid NOT NULL,
--     operation varchar(10) NOT NULL CHECK (operation IN ('UPSERT','DELETE')),
--     status varchar(20) NOT NULL DEFAULT 'PENDING', attempts int NOT NULL DEFAULT 0, next_retry_at timestamptz,
--     locked_at timestamptz, last_error text, created_at timestamptz NOT NULL DEFAULT now());
--   CREATE INDEX ON search_index_outbox (id) WHERE status = 'PENDING';
-- Finished rows are DELETED (or have a retention period); claim with FOR UPDATE SKIP LOCKED + a locked_at reaper.
