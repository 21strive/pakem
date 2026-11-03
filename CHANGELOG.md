# Changelog

Changes to this blueprint (not to the projects that use it). Newest entry first.

## 2026-11-03 — products and providers are the project's decision; the AWS deployment becomes a case study

- The guide no longer chooses products or services. Which cloud, container platform, CPU architecture, managed
  Postgres/Redis, search engine, object storage, frontend hosting, edge, DNS, email, log store, secret store, IaC tool,
  and CI a backend runs on is decided by the project and recorded in its `AGENTS.md` §1.1, next to the requirement each
  choice meets — `docs/00-principles.md` §F 22, `AGENTS.md` §1 "Products & providers", `README.md`.
- `docs/08-aws-infrastructure.md` → **`docs/08-infrastructure.md`** and `docs/09-cloudflare.md` →
  **`docs/09-frontend-and-storage.md`**: the same rules and incident lessons, written as requirements of each role
  (load balancer, container platform, secret store, static host, edge function, S3-compatible storage), with the section
  numbers kept.
- `docs/06-observability.md` describes the error tracker by role (log store → a small key-value store → email);
  `docs/02-database.md` §6 describes the pooler by mode (transaction endpoint for the application, session endpoint for
  manual work) instead of by port; `docs/05` §3.5 is email through any provider's API.
- New **`case-studies/`**: an illustration, not part of the standard. `case-studies/aws-supabase-cloudflare/` keeps the
  deployment that earlier versions of the guide prescribed — ECS on EC2 Graviton with the ECS-optimized AMI behind an ALB,
  Terraform and GitHub Actions, SSM, SES, CloudWatch, DynamoDB, Supabase through Supavisor, Redis Cloud, Typesense on
  EC2, Cloudflare Pages, Workers, R2 and DNS — with each choice mapped to the requirement it meets.
- Templates: `templates/backend/github/deploy.yml`, `templates/infra/terraform.yml`, and
  `templates/infra/prod.tfvars.example` moved to `case-studies/aws-supabase-cloudflare/templates/`;
  `templates/project/AGENTS.md` gets a providers table; the e2e stack's object storage env is `STORAGE_*` with
  `E2E_FAKE_S3_PORT`.

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
