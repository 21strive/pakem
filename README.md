<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/pakem-logo-white.svg">
    <img src=".github/assets/pakem-logo-black.svg" alt="pakem" height="64">
  </picture>
</h1>

> *Pakem* (Indonesian/Javanese): the canonical standard a wayang performance follows — here, the standard a backend
> is built to.

Universal guidance and working agreements for building a **production Go backend**: from the database schema, code
architecture, and endpoint design to caching, workers, E2E testing, and production deploys — including where the frontend
and object storage run (Cloudflare).

This repo is not application code. It holds **decisions that were already made and proven in production**, written as
rules for agents (Claude Code, etc.) and humans, plus template files to copy.

- Agent entry point: **[AGENTS.md](AGENTS.md)** (non-negotiable rules + order of work).
- Details per topic: **[docs/](docs/)**.
- Copy-ready files: **[templates/](templates/)**.

## The standard stack

```
             Cloudflare (DNS, proxy, TLS Full strict)
   ┌──────────────┬───────────────┬──────────────────────┬──────────────┐
   │ Pages: web   │ Pages: admin  │ Edge Worker (bots/OG,│ R2: assets & │
   │ SPA + Fns    │ dashboard     │ alias domains)       │ private files│
   └──────────────┴───────────────┴──────────────────────┴──────────────┘
                          │ api.<domain> (proxied)
                          ▼
   AWS: ALB → ECS on EC2 Graviton (arm64) ── api service (main) + worker service (worker)
          │            one Go image from ECR, configured by Terraform + SSM
          ├── Typesense on a private EC2 instance
          ├── SES, DynamoDB (error tracker), CloudWatch Logs
          ▼
   Supabase Postgres (pooler, the only source of truth)   +   Redis Cloud (redifu cache)
```

| Layer | Choice |
|---|---|
| Language & framework | Go, Fiber v2, sqlx + lib/pq, slog |
| Database | PostgreSQL (Supabase, through the Supavisor pooler), numbered SQL migrations |
| Cache | Redis + `github.com/21strive/redifu`; the cache follows writes through a trigger → `redifu_outbox` |
| Search | Typesense (private EC2), fed through an outbox |
| Queues & locks | outbox tables + Postgres advisory locks (not Redis) |
| Runtime | one binary: `main` (API), `worker [name]`, `command <name>` |
| Infra | Terraform (separate infra repo), ECS on arm64 EC2, ALB, one NAT, SSM Parameter Store, GitHub OIDC |
| Backend deploy | manual GitHub Actions `deploy.yml` (`workflow_dispatch`) → ECR → force new deployment |
| Frontend | Cloudflare Pages (Git integration; a push to the production branch = deploy) |
| Object storage | Cloudflare R2 (public through a custom CDN domain; private through presigned GETs) |
| Observability | JSON logs → CloudWatch, `trace_id`/`error_id`, error tracker CloudWatch → DynamoDB → email |
| Testing | unit + repository + architecture tests, cache parity tests, local HTTP E2E + regression against master |

## Contents

| Document | Topic |
|---|---|
| [docs/00-principles.md](docs/00-principles.md) | Core principles and decisions (read first) |
| [docs/01-architecture.md](docs/01-architecture.md) | One binary with 3 modes, layers, DI providers, folder structure, naming |
| [docs/02-database.md](docs/02-database.md) | Schema conventions, migrations, backfills, pools & pooler, TLS, local DB |
| [docs/03-api-design.md](docs/03-api-design.md) | URLs, response & error contract, pagination, auth, ownership, webhooks, feature switches, client handoff |
| [docs/04-caching.md](docs/04-caching.md) | The full redifu cache (outbox, drain, generations, lease, decorators, parity) + Redis rules |
| [docs/05-workers-and-integrations.md](docs/05-workers-and-integrations.md) | Workers & commands, the outbox pattern, notifications, search, third parties, money |
| [docs/06-observability.md](docs/06-observability.md) | Logs, tracing, error tracker, metrics, latency analysis |
| [docs/07-testing-and-e2e.md](docs/07-testing-and-e2e.md) | Unit/repository/architecture tests, cache parity, local E2E stack, regression, client tests |
| [docs/08-aws-infrastructure.md](docs/08-aws-infrastructure.md) | Terraform, ECS/ALB/network, config & secrets, image, deploy, rollback |
| [docs/09-cloudflare.md](docs/09-cloudflare.md) | Pages, Pages Functions, edge Worker, R2, DNS & TLS |
| [docs/10-workflow.md](docs/10-workflow.md) | Git & worktrees, docs, plan → E2E → deploy, production rules, agent sessions |
| [docs/11-checklists.md](docs/11-checklists.md) | Checklists: project bootstrap, new feature, new cache, migration, release |

## Using it for a new project

1. **Put the blueprint where agents can read it.** Recommended: copy (vendor) the `docs/` folder into the new backend repo
   as `docs/blueprint/` at a specific blueprint commit (record the SHA), so the project is self-contained and agents in
   CI/cloud can read it too. Alternative: clone this repo next to the project (`~/pakem`) and reference its
   absolute path.
2. **Create the backend repo's `AGENTS.md` from [templates/project/AGENTS.md](templates/project/AGENTS.md)**: fill in the
   project name, Go module, domain, region, and repo list (BE / web / mobile / infra / edge). `CLAUDE.md` contains
   `see @AGENTS.md`.
3. **Follow [docs/11-checklists.md](docs/11-checklists.md) §A (Bootstrap)** — repos, code skeleton, first migration, local
   E2E stack, infra repo, Cloudflare, first deploy.
4. Every project decision that **deviates** from the blueprint goes into the project's `AGENTS.md` ("Deviations from the
   blueprint") with its reason. Decisions that turn out to apply generally are brought back into this repo.

## Maintenance

- The patterns and numbers are what is standardized; names in examples are illustrative. Placeholders: `<project>`,
  `<app>`, `<module>`, `<org>`, `<domain>`, `<region>`.
- This repo **contains no secrets** (no credentials, account IDs, project refs, ARNs, or user data). Keep it that way:
  every example value uses a placeholder.
- When a practice changes in principle (e.g. a new cache pattern), update the related documents and add an entry to
  [CHANGELOG.md](CHANGELOG.md).
