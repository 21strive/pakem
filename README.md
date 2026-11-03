<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/pakem-logo-white.svg">
    <img src=".github/assets/pakem-logo-black.svg" alt="pakem" height="64">
  </picture>
</h1>

> *Pakem* (Indonesian/Javanese): the canonical standard a wayang performance follows — here, the standard a backend
> is built to.

Universal guidance and working agreements for building a **production Go backend**: from the database schema, code
architecture, and endpoint design to caching, workers, E2E testing, and production deploys.

This repo is not application code. It holds **decisions that were already made and proven in production**, written as
rules for agents (Claude Code, etc.) and humans, plus template files to copy. The decisions are about how the backend is
built; the products and services it runs on are left to the project that uses it.

- Agent entry point: **[AGENTS.md](AGENTS.md)** (non-negotiable rules + order of work).
- Details per topic: **[docs/](docs/)**.
- Copy-ready files: **[templates/](templates/)**.
- One real deployment, as an illustration: **[case-studies/](case-studies/)**.

## What pakem decides

| Layer | Decision |
|---|---|
| Language & framework | Go, Fiber v2, sqlx + lib/pq, slog |
| Database | PostgreSQL, the only source of truth; numbered SQL migrations; the application talks to it through a transaction-mode pooler |
| Cache | Redis + `github.com/21strive/redifu`; the cache follows writes through a trigger → `redifu_outbox` |
| Search | a search engine fed through an outbox; it only finds ids, Postgres answers |
| Queues & locks | outbox tables + Postgres advisory locks (not Redis) |
| Runtime | one binary: `main` (API), `worker [name]`, `command <name>`; one image, run as an API service and a worker service |
| Infra | infrastructure as code in a separate infra repo; non-secret settings committed with their reasons; secrets in a secret store; CI with federated, short-lived credentials |
| Backend deploy | manual, one at a time, verified until the running image digest is the one just built |
| Frontend | static hosting with Git-push deploys; an edge function in front for bots and alias domains |
| Object storage | S3-compatible; public files through a CDN domain, private files through short-lived presigned GETs |
| Observability | JSON logs on stdout, `trace_id`/`error_id`, our own error tracker (log store → a small store → email) |
| Testing | unit + repository + architecture tests, cache parity tests, local HTTP E2E + regression against master |

## What your project decides

Pakem does not choose products or services. The project picks them and records each choice, with the requirement it
meets, in its own `AGENTS.md`:

- the cloud and the container platform, and the CPU architecture of the hosts;
- where Postgres and Redis run (a managed provider or self-hosted), and which pooler sits in front of Postgres;
- the search engine and where it runs;
- the providers for object storage, frontend hosting, the edge, and DNS;
- the email provider, the log store, the error tracker's store, and the secret store;
- the infrastructure-as-code tool and the CI.

Whatever fills them, the roles stay the same:

```
                 Edge / DNS proxy (TLS verified end to end)
   ┌──────────────┬───────────────┬──────────────────────┬──────────────┐
   │ Static host: │ Static host:  │ Edge function (bots/ │ Object       │
   │ web SPA + fn │ admin dash.   │ OG, alias domains)   │ storage (S3) │
   └──────────────┴───────────────┴──────────────────────┴──────────────┘
                          │ api.<domain> (proxied)
                          ▼
   Load balancer → container platform ── api service (main) + worker service (worker)
          │            one Go image, configured from infra code + a secret store
          ├── search engine (private, data on a persistent volume)
          ├── email provider, log store, the error tracker's store
          ▼
   PostgreSQL behind a pooler (the only source of truth)   +   Redis (redifu cache)
```

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
| [docs/08-infrastructure.md](docs/08-infrastructure.md) | Infra as code, services & rollout, load balancer, network, config & secrets, image, deploy, rollback |
| [docs/09-frontend-and-storage.md](docs/09-frontend-and-storage.md) | Frontend hosting, functions, the edge function, object storage, DNS & TLS |
| [docs/10-workflow.md](docs/10-workflow.md) | Git & worktrees, docs, plan → E2E → deploy, production rules, agent sessions |
| [docs/11-checklists.md](docs/11-checklists.md) | Checklists: project bootstrap, new feature, new cache, migration, release |

## Case study

[case-studies/](case-studies/) shows how one production deployment chose its products and services, and which
requirement of the guide each one meets. It is an **illustration, not part of the standard**: borrow what fits, replace
what does not.

- **[AWS + Supabase + Cloudflare](case-studies/aws-supabase-cloudflare/README.md)** — ECS on EC2 Graviton (arm64) behind
  an ALB, Supabase Postgres through its pooler, Redis Cloud, Typesense on EC2, SES, CloudWatch, Cloudflare Pages, Workers,
  R2 and DNS, Terraform and GitHub Actions; with the `deploy.yml`, `terraform.yml`, and `prod.tfvars.example` it used.

## Using it for a new project

1. **Put the blueprint where agents can read it.** Recommended: copy (vendor) the `docs/` folder into the new backend repo
   as `docs/blueprint/` at a specific blueprint commit (record the SHA), so the project is self-contained and agents in
   CI/cloud can read it too. Alternative: clone this repo next to the project (`~/pakem`) and reference its
   absolute path.
2. **Create the backend repo's `AGENTS.md` from [templates/project/AGENTS.md](templates/project/AGENTS.md)**: fill in the
   project name, Go module, domain, region, the providers you chose, and the repo list (BE / web / mobile / infra / edge).
   `CLAUDE.md` contains `see @AGENTS.md`.
3. **Follow [docs/11-checklists.md](docs/11-checklists.md) §A (Bootstrap)** — decisions (providers included), repos, code
   skeleton, first migration, local E2E stack, infra repo, frontend & edge, first deploy.
4. Every project decision that **deviates** from the blueprint goes into the project's `AGENTS.md` ("Deviations from the
   blueprint") with its reason. Decisions that turn out to apply generally are brought back into this repo. Choosing a
   provider is not a deviation; it is the project's own decision.

## Maintenance

- The patterns and numbers are what is standardized; names in examples are illustrative. Placeholders: `<project>`,
  `<app>`, `<module>`, `<org>`, `<domain>`, `<region>`.
- **Products and providers stay out of the guide's rules.** `docs/`, `AGENTS.md`, and `templates/` describe roles and
  requirements; a product name appears there only as an example or a link to a case study. Provider-specific setup,
  commands, and quirks belong in `case-studies/`.
- This repo **contains no secrets** (no credentials, account IDs, project refs, ARNs, or user data). Keep it that way:
  every example value uses a placeholder.
- When a practice changes in principle (e.g. a new cache pattern), update the related documents and add an entry to
  [CHANGELOG.md](CHANGELOG.md).
