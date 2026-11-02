# 08 — AWS infrastructure & backend deploy

The backend runs on **AWS (ECS on EC2 Graviton)** behind **Cloudflare**. The database (Supabase Postgres) and
Redis (Redis Cloud) are **outside** the AWS stack and are referenced only by host. The frontend and object storage live on
Cloudflare ([09-cloudflare.md](09-cloudflare.md)). All AWS infrastructure and DNS is **Terraform** in a separate
infra repo; application deploys are a **manual GitHub Actions** workflow in the backend repo.

---

## 1. Topology

```
Internet
   │
Cloudflare (DNS + proxy, SSL "Full (strict)")
   │  api.<domain>  (CNAME → ALB, proxied)
   ▼
ALB  (public subnets a + b; 443 only from Cloudflare IP ranges; 80 → redirect 443)
   │  HTTP target group, health check GET /health
   ▼
ECS cluster on EC2 (Graviton, ARM64, ASG capacity provider, private subnets)
   ├── service <prefix>-api     : app image, command ["main"],   CPU autoscaling, behind the ALB
   └── service <prefix>-worker  : app image, command ["worker"], 1 task, no load balancer
   │
VPC private network
   ├── Typesense on EC2 (private subnet a, separate EBS volume) — reachable only from the ECS hosts
   └── egress through ONE NAT Gateway (AZ a)
   │
Outside the VPC:
   ├── Supabase Postgres (via the Supavisor pooler, IPv4)      ← 02-database.md
   ├── Redis Cloud (single node, Redis ≥ 6.2)                  ← 04-caching.md
   ├── Cloudflare R2 (object storage)                          ← 09-cloudflare.md
   ├── SES (email, via the task role)                          ← 05-workers-and-integrations.md
   ├── DynamoDB on-demand (error tracker) + CloudWatch Logs    ← 06-observability.md
   └── third-party services (payment gateway, WhatsApp, FCM, Google, Zoom, …)
```

**Hard constraints chosen** (keep them unless there is a strong, recorded reason):

- **No RDS/Aurora** — Postgres is on Supabase.
- **No Fargate** — ECS on EC2 (cheaper for a steady load; Graviton).
- **Typesense on its own EC2 instance**, not on ECS (it needs a persistent disk and a stable IP).
- **Exactly one NAT Gateway** (cost; single-AZ egress availability is accepted).
- **One image for the API and the worker**; the only difference is `command`.
- **One AWS environment (production).** There is no mandatory backend staging: validation is done with local E2E
  against the production schema/dump, followed by a staged rollout in production behind feature switches
  ([07-testing-and-e2e.md](07-testing-and-e2e.md), [10-workflow.md](10-workflow.md)).
- **One dedicated AWS account per project.** Do not piggyback on another project's account; Terraform locks the account
  with `allowed_account_ids`.

Starting sizes proven sufficient for a small-to-medium SaaS:

| Component | Value |
|---|---|
| ECS host | `m6g.large`, ASG min 1 / desired 1 / max 3, capacity provider managed scaling target 100 |
| API service | desired 1, autoscaling 1–4 tasks, CPU target 70%, scale-out cooldown 60 s, scale-in 300 s |
| Worker service | desired 1, no autoscaling |
| Typesense | `t4g.small`, 20 GB EBS data volume |
| Region | one region close to the users (e.g. `ap-southeast-1`) |
| Logs | CloudWatch Logs `/ecs/<prefix>/api` and `/ecs/<prefix>/worker`, 30-day retention |

All resource names use the prefix `<project>-<environment>` (e.g. `<project>-prod-cluster`,
`<project>-prod-api`, `<project>-prod-worker`, `<project>-prod-app` for ECR).

---

## 2. Infra repo

A separate repo, `<project>-prod-infra`:

```
bootstrap/          # run ONCE by a human, LOCAL state
  main.tf           #   S3 state bucket (versioned, encrypted, public access blocked) + DynamoDB lock table
  oidc.tf           #   GitHub OIDC provider + Terraform CI role + backend deploy role
terraform/          # root module, S3 backend, run by CI
  backend.tf providers.tf main.tf variables.tf outputs.tf
  prod.tfvars       #   COMMITTED: every non-secret setting (one source of truth for local & CI)
  terraform.tfvars  #   gitignored: secrets for local runs
  modules/
    networking/     #   VPC, public/private subnets in 2 AZs, IGW, one NAT, route tables
    security/       #   security groups + IAM (execution role, task role, instance profile)
    container/      #   one ECR repository (API + worker share the image)
    compute/        #   ECS cluster + ASG capacity provider, task defs & services, Typesense EC2, log groups, DynamoDB table
    load_balancer/  #   ALB, target group, listeners
    email/          #   SES domain identity + DKIM + MAIL FROM
    cloudflare/     #   DNS records (api → ALB, SES records)
    monitoring/     #   CloudWatch dashboard (ALB, ECS services, cluster capacity)
scripts/
  load-env.sh       #   sets the AWS profile + fetches the Cloudflare token from the keychain, then verifies both
  put-secrets.sh    #   fills SSM parameters from an env file (values are not printed)
.github/workflows/terraform.yml
README.md SETUP.md  #   architecture + setup order from scratch (the chicken-and-egg problem explained)
.terraform-version  #   pinned Terraform version
```

### 2.1 Why `bootstrap/` exists

Two circular dependencies:

1. **CI needs the S3 backend, and the backend is created by Terraform** → `bootstrap/` uses local state to create the
   bucket + lock table (both `prevent_destroy`).
2. **CI needs an IAM role, and the role is created by Terraform** → the OIDC roles are created by a human with admin
   credentials, in `bootstrap/`.

| Directory | Run by | Frequency | State |
|---|---|---|---|
| `bootstrap/` | A human, from a laptop | Once in a lifetime (and when adding a role) | Local (gitignored, contains no secrets) |
| `terraform/` | GitHub Actions (plan on PRs, apply on `main`) | Every change | Remote (S3) |

### 2.2 Terraform CI (`.github/workflows/terraform.yml`)

- Watches only `terraform/**` and the workflow file itself.
- **PR:** `terraform fmt -check -recursive` → `init` → `validate` → `plan -var-file=prod.tfvars`.
- **Push to `main`:** `apply -auto-approve -var-file=prod.tfvars`, bound to the GitHub Environment `production`
  (add a required reviewer if you want a manual gate).
- AWS credentials through OIDC (`aws-actions/configure-aws-credentials`), no static access keys.
- The only CI secrets: `AWS_TERRAFORM_ROLE_ARN`, `CLOUDFLARE_API_TOKEN`, and Terraform secrets as `TF_VAR_<name>`.
- **The Terraform version is pinned in two places** (`.terraform-version` and `TF_VERSION` in the workflow). A newer
  Terraform upgrades the state format, and the older CI version then refuses to read it. Upgrading = change both at once.

### 2.3 GitHub → AWS OIDC

- One OIDC provider, `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
- **The `sub` condition MUST** restrict the role to specific repos. Without it, any GitHub repo can take over the role.
  Include two patterns per repo if the organization uses *immutable identifiers*:
  `repo:<org>/<repo>:*` and `repo:<org>@*/<repo>@*:*`.
- **Role 1 — Terraform CI (infra repo):** broad within each managed service (EC2, ELB, ECS, ECR, autoscaling, logs, SES,
  CloudWatch, SSM write/delete/tag, ACM read, KMS for SecureString), **locked to one region**; IAM restricted to the
  stack prefix (`role/<project>-<env>-*`), `iam:PassRole` only to `ec2`/`ecs-tasks`/`ecs`; access to the state bucket +
  lock table; the application's DynamoDB tables.
- **Role 2 — deploy (backend repo):** only `ecr:GetAuthorizationToken`, push to **one** ECR repository, and
  `ecs:UpdateService`/`DescribeServices` on the **two** services + task reads. **No `ecs:RegisterTaskDefinition`:**
  task definitions belong to Terraform.

---

## 3. Application configuration on ECS

The API and the worker are the same binary, so they receive **identical** configuration, assembled **once** in
`modules/compute/ecs.tf` (one `local`) and used by both task definitions.

### 3.1 Non-secret: `app_environment` in `prod.tfvars`

- A `KEY = "value"` map that appears verbatim in the task definition. It **must not** contain passwords, tokens, or keys.
- Every key gets a comment: what it means, its default in the code, when and with whose approval its value is changed,
  its prerequisites, and how to roll it back. That comment is operational documentation (example below).
- **Infrastructure-derived values** (Typesense private IP, error tracker table/log group names) are computed by Terraform
  as defaults (`derived_environment`) and then `merge`d with `app_environment` (tfvars wins when set).
  Do not copy IPs/names by hand: a copied value is bound to go stale without anyone noticing.
- Keys that have no value yet are **commented out**, not `KEY = ""` (an empty string overrides `.env` — godotenv checks
  whether a key exists, not what it contains).

Example of the feature-switch comment pattern:

```hcl
  # ---- Marketplace ----
  # Public provider directory: GET /marketplace/listings… and the marketplace-listings worker.
  # Off = both endpoints 404 and no account is queued.
  # Turned on <date> with the user's OK, after migration NNN and backend deploy <sha>.
  # After apply: run the backfill-marketplace-listings command once.
  MARKETPLACE_ENABLED = "true"
```

### 3.2 Secrets: `app_secret_keys` → SSM Parameter Store

- `prod.tfvars` holds only the secret **names**. Each name maps to an SSM SecureString parameter
  `<ssm_parameter_prefix>/<NAME>` (e.g. `/<project>/prod/JWT_API_SECRET`) that the ECS agent pulls when the container
  starts (`secrets[].valueFrom`).
- Fill in the values with `scripts/put-secrets.sh <env-file>`; values > 1 KB (service account JSON, base64 certificates)
  are filled in **from a file**, not through interactive input (the terminal truncates long lines without telling you).
- **Fill in the SSM parameters BEFORE the change reaches `main`.** CI applies right away, and a task that references a
  parameter that does not exist yet fails to start.
- Secrets used by both a server and the application (e.g. the Typesense API key) are created by Terraform from one
  variable, so the two can never differ.
- Secrets the code no longer reads are removed from the list (record the reason in a comment).
- The execution role has `ssm:GetParameters` on that prefix + `kms:Decrypt` with a `kms:ViaService` condition.

### 3.3 Kill switches and prerequisites

Switches that turn a channel/feature on are written explicitly in the tfvars, **with their prerequisites**:

- A switch that depends on new code: **deploy the backend first, then apply** (an old image + a new switch can
  bring the process down).
- A switch that depends on a secret: **fill in SSM first, then apply**.
- A worker started without a name runs **all** workers in one process; a channel configuration validation that fails at
  start (`os.Exit(1)`) brings down the **whole** worker (email dies with it). Therefore: validation fails → turn off only
  that channel, or make sure the configuration is valid before the switch is turned on.
- Turning a switch off (`"false"`) is an **instant rollback with no deploy and no data change** — this is why
  every risky feature gets a switch.

---

## 4. ECS, ALB, network

### 4.1 Cluster & hosts

- ECS-optimized Amazon Linux arm64 AMI from the public SSM parameter
  (`/aws/service/ecs/optimized-ami/amazon-linux-2/arm64/recommended/image_id`).
- Launch template: user data registers the host with the cluster; IMDSv2 required (`http_tokens = "required"`, hop limit 2).
- ASG in the private subnets, `protect_from_scale_in`, capacity provider with managed termination protection.
- Container Insights enabled.
- **Every apply bumps the launch template's `image_id`** (latest AMI from SSM). This is routine: the ASG uses `$Latest`
  without an instance refresh, so running hosts are not replaced; only hosts added by a scale-out use the new AMI.

### 4.2 Task definition & service

- Network mode `bridge`, `hostPort = 0` (dynamic host port); the ALB reaches the hosts on 32768–65535 (the host SG only
  accepts traffic from the ALB SG).
- `environment = local.app_environment`, `secrets = local.app_secrets`, log driver `awslogs` to one log group per service.
- Image `<ecr>/<project>-<env>-app:latest`; a deploy is just a **force new deployment** (the task def does not change).
- **API service:** `deployment_minimum_healthy_percent = 50`, `maximum_percent = 200` (rolling on a single host without
  a deadlock), target tracking autoscaling on `ECSServiceAverageCPUUtilization`, `ignore_changes = [desired_count]`.
- **Worker service:** desired 1, `minimum_healthy_percent = 0`, `maximum_percent = 100` (the old task may stop before
  the new one is healthy — never two worker sets at the same time).
- **`deployment_circuit_breaker { enable = true, rollback = true }` on BOTH services.** Incident lesson: a new revision
  panicked at boot (wrong DB host) and failed over and over, the rollout stayed `IN_PROGRESS`, and traffic was served by
  old-revision tasks that happened not to have restarted yet — the API looked healthy while its new revision was in a
  crash loop. The worker failed 146 times without anyone noticing. The circuit breaker stops the attempts and returns to
  the last healthy revision.
- **Task definitions change only through Terraform.** Values changed in the console do not enter the state and are
  overwritten by the next apply (this once put the API and the worker into a crash loop).

### 4.3 ALB

- Public subnets in 2 AZs; HTTPS 443 listener with `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` and a
  **Cloudflare Origin Certificate** imported into ACM by hand (the private key never enters Terraform
  state; ACM does not renew imported certificates — use a long validity, 15 years).
- HTTP 80 listener → 301 redirect to 443.
- HTTP target group to the container port (e.g. 8000), health check `GET /health`, matcher `200-399`, interval 30,
  healthy/unhealthy threshold 3. **Make sure the container port and the health check path match the application** (it
  was once set to 8080 while the application listened on 8000 — the health check never passed).
- **The ALB security group only accepts 443 from Cloudflare IP ranges** (data source `cloudflare_ip_ranges`, IPv4 +
  IPv6). Consequence: DNS records must be **proxied**; DNS-only mode or SSL "Flexible" (Cloudflare to the origin over
  port 80) takes the whole site down with 521/522. Because of that data source, the Cloudflare token is needed as early
  as `plan`.

### 4.4 Network

- A `/16` VPC, two public subnets (ALB, NAT) and two private subnets (ECS hosts, Typesense) across two AZs.
- One NAT Gateway (EIP) in AZ a; private routes go through the NAT. The NAT's public IP is stable → it is used to restrict
  server-side third-party API keys (e.g. a Google Maps server key restricted to the NAT IP).
- **The VPC is IPv4-only.** A database host that only has an AAAA record (Supabase direct connection) cannot be reached
  (`connect: cannot assign requested address`, panic at boot; the API and the worker both die because the connections are
  opened before the mode branch). Use a pooler that has an A record ([02-database.md](02-database.md)).

### 4.5 Typesense on EC2

- Amazon Linux 2023 arm64 AMI, private subnet a; user data installs & runs Typesense with the API key from a
  Terraform variable; `ignore_changes = [ami]` so the instance is not replaced on every new AMI.
- **A separate EBS data volume** (`aws_ebs_volume` + attachment) so the data survives when the instance is replaced.
- The SG only accepts the Typesense port from the ECS host SG; no TLS (private network), `TYPESENSE_PROTOCOL = "http"`.
- `TYPESENSE_HOST` is derived from `aws_instance.typesense.private_ip` (it changes whenever the instance is replaced).
- Admin access to the instance goes through SSM Session Manager (SSM instance profile), not open SSH.

### 4.6 Runtime IAM

| Role | Contents |
|---|---|
| ECS host instance role | `AmazonEC2ContainerServiceforEC2Role` + `AmazonSSMManagedInstanceCore` |
| Execution role | `AmazonECSTaskExecutionRolePolicy` + `ssm:GetParameters` on the prefix + `kms:Decrypt` via SSM |
| Task role (application) | `ses:SendEmail` restricted to the domain identity in the sending region; DynamoDB item ops on the error tracker table; `logs:FilterLogEvents` on the application log groups |

The application uses SES **through the SDK with the task role**, not SMTP — there is no access key in env or SSM.
`SES_REGION` must match the region variable that forms the identity ARN in the policy.

### 4.7 SES, email DNS, monitoring

- SES domain identity + DKIM + custom MAIL FROM; DNS records created by Terraform in Cloudflare: TXT verification, three
  DKIM CNAMEs (**not** proxied), MAIL FROM MX + SPF, root SPF, DMARC `p=quarantine` (+ optional `rua`).
- A new SES account = **sandbox** (200 emails/day, verified addresses only). Request production access before email is used
  for user verification.
- CloudWatch dashboard for the ALB (requests, 5xx, latency), the ECS services (CPU/memory), and cluster capacity.
- Error tracker DynamoDB table: on-demand, `deletion_protection_enabled = true` + `prevent_destroy` (it holds the
  recipient list & statuses filled in by admins). See [06-observability.md](06-observability.md).

---

## 5. Application image

`Dockerfile` (template: [`templates/backend/Dockerfile`](../templates/backend/Dockerfile)):

- Builder `golang:<version>-alpine`; private modules through `GOPRIVATE=github.com/<org>/*` + `ARG TOKEN` and
  `git config url."https://${TOKEN}:x-oauth-basic@github.com/".insteadOf`.
- `ARG GIT_SHA` and `ARG BUILD_TIME` → `-ldflags "-X …/app/buildinfo.Revision=${GIT_SHA} -X …/app/buildinfo.Time=${BUILD_TIME}"`.
  Both are **mandatory** in production images: `Revision` = the cache index generation, `Time` = which build is newer when
  two builds share Redis ([04-caching.md](04-caching.md)). A build without the stamp runs as "dev" and logs a WARN.
- `CGO_ENABLED=0 GOOS=linux go build -o ./<app> ./app/cmd` → static binary.
- Runtime `alpine`; copy the binary; **`touch .env` (empty)** (godotenv needs the file to exist; the real configuration
  comes from ECS); `EXPOSE <port>`; `ENTRYPOINT ["/<dir>/<app>"]`, `CMD ["main"]`. The ECS `command` overrides `CMD`, not
  `ENTRYPOINT`, so the task definition only needs the subcommand (`["main"]`, `["worker"]`).
- `.dockerignore`: `.git` (the remote URL may contain a PAT), `.env*`, `app/mocks`, `**/*_test.go`, `scripts`, `docs`,
  `.github`, local binaries.
- **Platform `linux/arm64` is mandatory.** An amd64 image pushes without complaint and then dies at runtime with
  `exec format error`.

---

## 6. Backend deploy (`.github/workflows/deploy.yml`)

Template: [`templates/backend/github/deploy.yml`](../templates/backend/github/deploy.yml).

- **Only `workflow_dispatch`** — on purpose. An automatic deploy on every push to `master` makes `master` unusable for
  holding changes that are not ready for release, for combining several merges into one rollout, or for late-night
  merges. Production moves when someone decides it does: `gh workflow run deploy.yml --ref master`.
- `permissions: { id-token: write, contents: read }`; `concurrency: { group: deploy-prod, cancel-in-progress: false }`
  (two deploys never race).
- **Native arm64** runner (`ubuntu-24.04-arm`); a Go build under QEMU emulation takes 20–40 minutes.
- Steps: checkout → compute `short_sha` and `build_time` → AWS OIDC (`AWS_DEPLOY_ROLE_ARN`) → ECR login → buildx →
  `docker/build-push-action` (`platforms: linux/arm64`, `provenance: false`, tags `:latest` + `:<short_sha>`,
  build-args `TOKEN`, `GIT_SHA`, `BUILD_TIME`, cache `type=gha`) → `aws ecs update-service --force-new-deployment`
  for the API and worker services → rollout state report → summary in the step summary.
- One run takes ±3 minutes.

### 6.1 Before pressing deploy

1. `git fetch`; compare the **last deployed SHA** (`headSha` of the last successful run) with `origin/master` — a deploy
   ships master's HEAD, so make sure no one else's unready work ships along with it.
2. The migrations the new code needs **have already been run** in production (expand first, see
   [02-database.md](02-database.md)), with the user's approval.
3. New secrets are already in SSM; feature switches are still off (or their prerequisites are met).
4. Take the **deploy lock** if there are several sessions/agents ([10-workflow.md](10-workflow.md)).

### 6.2 Verifying the rollout

1. Wait for the run to finish **in the foreground**: `gh run watch <id> --exit-status` (a background notification once
   arrived while the run was still building — do not report "deployed" before checking it directly).
2. `aws ecs wait services-stable --cluster <cluster> --services <api> <worker>`; rollout state `COMPLETED`.
3. Compare the `imageDigest` of every running task with the ECR digest of the `<short_sha>` tag.
4. Read the `/ecs/<prefix>/api` and `/worker` logs: the build line (`revision` = the new SHA), no new ERROR/panic,
   the cache lease taken by the new build.
5. Probe the public API: unknown route → 404, admin route without a token → 401 (proves the new routes are live), and
   the feature's main flow.
6. Record it in the deploy log (SHA, run id, time, migrations, switches).

### 6.3 Rollback

- **Faulty feature:** turn off its switch (infra apply) — fastest, no data change.
- **Faulty binary:** run `deploy.yml` from the previous ref/sha (`--ref <branch/tag>` or a revert on master);
  the circuit breaker already handles revisions that never become healthy.
- **Migration:** the expand/contract design keeps the old binary working on the new schema; do not roll back the schema
  unless you have no other choice, and only with approval.
- The cache has its own rollback rules (generation/lease/epoch): [04-caching.md](04-caching.md) §Operations.

---

## 7. Commands as one-off tasks

Production commands (backfill, purge, retry) run as **one-off ECS tasks** from the worker task definition
with a `command` override (`["command","<name>","--dry-run"]`), or from an operator machine with the production env —
both use the same pooler connection budget, so count them within the pool limits ([02-database.md](02-database.md)).
Always `--dry-run` first, report how much will change, and ask for approval if it is destructive (deletes/overwrites data).

---

## 8. Changing infra

1. Branch in the infra repo; change `prod.tfvars`/modules.
2. **Run a read-only local plan first** (`terraform plan -lock=false -var-file=prod.tfvars`; without a Cloudflare token:
   `-refresh=false` + a 40-character dummy token). The plan may contain only your changes (+ the known launch template
   AMI drift).
3. Fill in SSM for new secrets.
4. Merge/push to `main` → CI applies (±1 minute). **An infra apply redeploys the ECS services** when a task definition
   changes: treat it as a deploy (deploy lock, rollout verification).
5. State locked because an apply was killed: `terraform force-unlock <LOCK_ID>`, after making sure no other apply is running.

### 8.1 Common problems

| Symptom | Usual cause |
|---|---|
| `terraform init` fails, backend does not exist | `bootstrap/` has not been run / bucket name does not match |
| ECS task keeps restarting | image not in ECR yet, amd64 image, DB host unreachable, SSM parameter does not exist yet |
| ALB 502/503 | unhealthy targets: container port / health check path mismatch |
| Cloudflare 521/522 | record not proxied, or SSL mode is not Full (strict) |
| Cloudflare provider error during plan | `CLOUDFLARE_API_TOKEN` not exported (needed by the IP range data source) |
| CI rejects the state | local Terraform version is newer than CI's |
| CI apply fails Cloudflare authentication | Cloudflare token expired (create an infra token that never expires, or record its expiry date) |

### 8.2 Things deliberately not managed by Terraform

- Cloudflare Origin certificate → imported into ACM by hand.
- Image build & push → the application repo's pipeline.
- Leaving the SES sandbox → AWS support ticket.
- Database (Supabase), Redis (Redis Cloud), Cloudflare Pages/R2/Workers (managed in the Cloudflare dashboard/wrangler,
  see [09-cloudflare.md](09-cloudflare.md)).

---

## 9. Setup from scratch (short)

The full sequence is in [11-checklists.md](11-checklists.md) §Bootstrap. The essentials:

1. A dedicated AWS account for the project + a named CLI profile (do not use `default` if the laptop has other accounts).
2. Collect the external values: Cloudflare token (Zone DNS Edit, restricted to the zone), zone ID, Origin Certificate → ACM,
   SSL mode Full (strict), Typesense API key (`openssl rand -hex 32`).
3. Apply `bootstrap/` (state bucket, lock table, OIDC + roles).
4. Fill in `prod.tfvars` (non-secret) and `terraform.tfvars` (local secrets); run the first apply from a laptop.
5. Push the first image (`docker buildx build --platform linux/arm64 … --push`); the services come up on their own.
6. Fill in the GitHub Secrets (`AWS_TERRAFORM_ROLE_ARN`, `CLOUDFLARE_API_TOKEN`, `TF_VAR_*`) in the infra repo, and
   (`AWS_DEPLOY_ROLE_ARN`, `GOPRIVATE_TOKEN`) in the backend repo.
7. Fill in SSM with `put-secrets.sh`, then run `deploy.yml`.
