# Changelog

Changes to this blueprint (not to the projects that use it). Newest entry first.

## 2026-11-02 — first version

- `AGENTS.md` — core rules, the order of work for a new backend, how to work, production, communication.
- `docs/00`–`11` — principles, architecture, database, API design, redifu caching, workers & integrations, observability,
  testing & E2E, AWS infrastructure, Cloudflare, workflow, checklists.
- `templates/` — backend (Dockerfile, Makefile, deploy.yml, local E2E stack, SQL for migrations/outbox/cache), infra
  (Terraform CI, `prod.tfvars.example`), documents (plan, handoff, runbook, backfill, CHANGELOG entry), session files
  (COMMON, HANDOFF, E2E, RELEASE), and a project `AGENTS.md`.
- Practices learned from production incidents that are not common practice yet are marked **(improvement)** in every
  document.
