# Case study — AWS + Supabase + Cloudflare

An illustration, not part of the standard: how one production deployment of a pakem backend (a small-to-medium SaaS with
a web app, mobile apps, and an internal dashboard) chose its products and services, why, and which requirement of the
guide each one meets. A project can make every one of these choices differently and still follow pakem.

The numbers below (instance sizes, pool sizes, costs, timings) are what this deployment ran and measured. They are a
reference point, not a target.

---

## 1. The deployment

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

The backend runs on **AWS (ECS on EC2 Graviton)** behind **Cloudflare**. The database (Supabase Postgres) and Redis
(Redis Cloud) are **outside** the AWS stack and are referenced only by host. The frontend, object storage, DNS, and edge
live on Cloudflare. All AWS infrastructure and DNS is **Terraform** in a separate infra repo; backend deploys are a
**manual GitHub Actions** workflow in the backend repo.

---

## 2. Each choice and the requirement it meets

Swap any row for your own provider: the middle column says what the replacement must do.

| Role | Requirement in the guide | This deployment |
|---|---|---|
| DNS, edge proxy, TLS | records proxied, TLS verified end to end, the origin reachable only through the edge ([09](../../docs/09-frontend-and-storage.md) §1) | Cloudflare DNS + proxy, SSL "Full (strict)", a Cloudflare Origin Certificate on the ALB |
| Web app & admin dashboard | static hosting, Git-push deploys, previews ([09](../../docs/09-frontend-and-storage.md) §2) | Cloudflare Pages, Pages Functions on three paths |
| Bot HTML, alias domains | an edge function in front of the static site ([09](../../docs/09-frontend-and-storage.md) §3) | a Cloudflare Worker |
| User files | S3-compatible object storage, presigned PUT/GET ([09](../../docs/09-frontend-and-storage.md) §4) | Cloudflare R2: a public bucket on `cdn.<domain>`, a private bucket |
| Load balancer | TLS, health check `/health`, accepts only the edge ([08](../../docs/08-infrastructure.md) §4.3) | ALB whose security group accepts only Cloudflare IP ranges |
| Container platform | one image as two services, rollout settings, circuit breaker + rollback ([08](../../docs/08-infrastructure.md) §4.2) | ECS on EC2, ECS-optimized AMI, bridge networking |
| CPU architecture | the image is built for the hosts' architecture, on a native runner ([08](../../docs/08-infrastructure.md) §5) | arm64 (Graviton), GitHub's `ubuntu-24.04-arm` runner |
| Image registry | one repository, tags `latest` + `<short_sha>` ([08](../../docs/08-infrastructure.md) §6) | ECR |
| Infrastructure as code | a separate infra repo, plan on PR, apply on `main` ([08](../../docs/08-infrastructure.md) §2) | Terraform (S3 state + DynamoDB lock), GitHub Actions |
| CI credentials | short-lived federated credentials, two narrow roles ([08](../../docs/08-infrastructure.md) §2.3) | GitHub OIDC → two IAM roles |
| Secrets | a secret store, only names in the repo ([08](../../docs/08-infrastructure.md) §3.2) | SSM Parameter Store SecureString |
| Fixed egress IP | one address third parties can allow-list ([08](../../docs/08-infrastructure.md) §4.4) | one NAT Gateway with an Elastic IP |
| Postgres | Postgres behind a transaction-mode pooler, a session endpoint for manual work ([02](../../docs/02-database.md) §6) | Supabase, Supavisor pooler: transaction `:6543`, session `:5432` |
| Redis | a single node, ≥ 6.2 ([04](../../docs/04-caching.md) §1) | Redis Cloud |
| Search engine | persistent data, private, one pinned version ([05](../../docs/05-workers-and-integrations.md) §4) | Typesense in Docker on a private EC2 instance with its own EBS volume |
| Email | a provider API, not SMTP; the domain authenticated ([05](../../docs/05-workers-and-integrations.md) §3.5) | SES v2 through the SDK and the task role |
| Logs | JSON on stdout into a store you can query ([06](../../docs/06-observability.md) §1, §6) | CloudWatch Logs + Logs Insights |
| Error tracker store | a small store outside the main database, with conditional writes ([06](../../docs/06-observability.md) §4) | DynamoDB on-demand |
| Dashboard & alarms | load balancer, services, hosts ([06](../../docs/06-observability.md) §7) | a CloudWatch dashboard from Terraform |
| Backend deploy | manual trigger, one at a time, verified by digest ([08](../../docs/08-infrastructure.md) §6) | GitHub Actions `workflow_dispatch` → ECR → `aws ecs update-service --force-new-deployment` |

---

## 3. Choices made here, and why

These were the constraints this deployment kept. They are reasons, not rules: another project with another load, budget,
or team will weigh them differently.

- **No RDS/Aurora** — Postgres is on Supabase, outside the AWS stack.
- **No Fargate** — ECS on EC2 (cheaper for a steady load), on Graviton.
- **Typesense on its own EC2 instance**, not on ECS: it needs a persistent disk and a stable address.
- **Exactly one NAT Gateway** (cost; single-AZ egress availability is accepted). Its fixed IP is what third parties
  allow-list.
- **One AWS environment (production)** and **one dedicated AWS account for the product**; Terraform locks the account with
  `allowed_account_ids`.
- **Frontend, files, DNS, and edge on Cloudflare**: one provider for everything the browser touches, with the API proxied
  through the same zone.

## 4. Sizes this deployment ran

| Component | Value |
|---|---|
| ECS host | `m6g.large`, ASG min 1 / desired 1 / max 3, capacity provider managed scaling target 100 |
| API service | desired 1, autoscaling 1–4 tasks, CPU target 70%, scale-out cooldown 60 s, scale-in 300 s |
| Worker service | desired 1, no autoscaling |
| Typesense | `t4g.small`, 20 GB EBS data volume |
| Region | one region close to the users (e.g. `ap-southeast-1`) |
| Logs | CloudWatch Logs `/ecs/<prefix>/api` and `/ecs/<prefix>/worker`, 30-day retention |
| Postgres | PostgreSQL 17.6 on Supabase Micro compute (`max_connections` 60), Supavisor Pool Size 15, Max Client Connections 200 |
| Pools per process | write 10, read 10, payment library 2 |

All AWS resource names use the prefix `<project>-<environment>` (e.g. `<project>-prod-cluster`, `<project>-prod-api`,
`<project>-prod-worker`, `<project>-prod-app` for ECR).

---

## 5. Parts

| Part | What it covers |
|---|---|
| [01 — Backend on AWS](01-backend-on-aws.md) | Terraform repo, OIDC roles, ECS on EC2 Graviton, ALB, network, SSM, Typesense host, SES, image, `deploy.yml`, verification, setup |
| [02 — Postgres on Supabase](02-postgres-on-supabase.md) | Supavisor endpoints, the IPv4-only VPC, pool numbers, binary parameters rollout, TLS, dumps |
| [03 — Cloudflare](03-cloudflare.md) | DNS and TLS, Pages and Pages Functions, the edge Worker, R2, credentials and tools |
| [04 — Observability on AWS](04-observability-on-aws.md) | CloudWatch Logs, the error tracker on CloudWatch + DynamoDB + SES, Logs Insights, dashboard and alarms |

## 6. Templates

The files this deployment used, with its products filled in. Copy them only if you made the same choices.

| File | What it is |
|---|---|
| [templates/deploy.yml](templates/deploy.yml) | The backend's manual GitHub Actions deploy: native arm64 build → ECR → force a new ECS deployment |
| [templates/terraform.yml](templates/terraform.yml) | The infra repo's Terraform CI: plan on pull requests, apply on `main`, AWS credentials through OIDC |
| [templates/prod.tfvars.example](templates/prod.tfvars.example) | The committed non-secret settings: network, ECS, ALB, DNS, the application env, the SSM secret names |
