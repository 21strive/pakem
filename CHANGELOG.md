# Changelog

Changes to this blueprint (not to the projects that use it). Newest entry first.

## 2026-11-02 — entity initiators and `*redifu.Record`

- Every entity has an initiator `New<Entity>()` that allocates it and calls `redifu.InitRecord`; a new instance is
  created only through it, never as an inline struct literal; rows that already exist (read from the DB, cache
  projection targets and stubs) never go through it — `docs/01-architecture.md` §6.1, with the rule in `AGENTS.md` §1,
  `docs/02-database.md` §1.1, `docs/11-checklists.md` §B, and `templates/project/AGENTS.md`.
- Everything the cache stores embeds `*redifu.Record`, satellites, handles, and computed records included: they no
  longer implement `redifu.Blueprint` with hand-written no-op methods — `docs/04-caching.md` §2.5 and §11.

## 2026-11-02 — first version

- `AGENTS.md` — core rules, the order of work for a new backend, how to work, production, communication.
- `docs/00`–`11` — principles, architecture, database, API design, redifu caching, workers & integrations, observability,
  testing & E2E, AWS infrastructure, Cloudflare, workflow, checklists.
- `templates/` — backend (Dockerfile, Makefile, deploy.yml, local E2E stack, SQL for migrations/outbox/cache), infra
  (Terraform CI, `prod.tfvars.example`), documents (plan, handoff, runbook, backfill, CHANGELOG entry), session files
  (COMMON, HANDOFF, E2E, RELEASE), and a project `AGENTS.md`.
- Practices learned from production incidents that are not common practice yet are marked **(improvement)** in every
  document.
