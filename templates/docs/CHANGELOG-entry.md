### <Title phrased as an outcome, e.g. "Widgets: owners can archive a widget">

Plan [`docs/plans/<x>.md`](docs/plans/<x>.md); reference [`docs/reference/<y>.md`](docs/reference/<y>.md).
<Short background, the incident date if any.> **Requires migration `NNN_<x>.sql`** (additive, run before deploy).
New env `WIDGET_ENABLED` (default `false`; routes answer 404 while off). Ships with web `feat/<x>`.

- `[API]` `POST /widget/{widget_uuid}/archive` — 200 with the archived widget; 404 `widget not found` for a widget
  that is missing or not the caller's; 409 `widget already archived`.
- `[DB]` `widgets.archived_at timestamptz NULL`.
- `[DEV]` `TestWidgetArchive` (T1–T6); fails on master at the archive call (404 route).
