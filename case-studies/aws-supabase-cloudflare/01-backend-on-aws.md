# Case study 01 — Backend on AWS: ECS on EC2 Graviton, Terraform, GitHub Actions

An illustration, not part of the standard: how the [case study](README.md) deployment met
[08-infrastructure.md](../../docs/08-infrastructure.md) on AWS. The section numbers follow that chapter, so each part
here sits next to the requirement it implements.

---

## 1. Topology on AWS

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
   ├── Supabase Postgres (via the Supavisor pooler, IPv4)      ← 02-postgres-on-supabase.md
   ├── Redis Cloud (single node, Redis ≥ 6.2)
   ├── Cloudflare R2 (object storage)                          ← 03-cloudflare.md
   ├── SES (email, via the task role)                          ← §4.7
   ├── DynamoDB on-demand (error tracker) + CloudWatch Logs    ← 04-observability-on-aws.md
   └── third-party services (payment gateway, WhatsApp, FCM, Google, Zoom, …)
```

The reasons behind the shape (no RDS, no Fargate, one NAT, one account) and the sizes are in the
[overview](README.md) §3–§4.

---

## 2. Infra repo (Terraform)

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

### 2.1 `bootstrap/`

The two circular dependencies of [08](../../docs/08-infrastructure.md) §2.1, on AWS:

1. **CI needs the S3 backend, and the backend is created by Terraform** → `bootstrap/` uses local state to create the
   bucket + DynamoDB lock table (both `prevent_destroy`).
2. **CI needs an IAM role, and the role is created by Terraform** → the OIDC roles are created by a human with admin
   credentials, in `bootstrap/`.

| Directory | Run by | Frequency | State |
|---|---|---|---|
| `bootstrap/` | A human, from a laptop | Once in a lifetime (and when adding a role) | Local (gitignored, contains no secrets) |
| `terraform/` | GitHub Actions (plan on PRs, apply on `main`) | Every change | Remote (S3) |

### 2.2 Terraform CI (`.github/workflows/terraform.yml`)

Template: [templates/terraform.yml](templates/terraform.yml).

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
`modules/compute/ecs.tf` (one `local`) and used by both task definitions. Template:
[templates/prod.tfvars.example](templates/prod.tfvars.example).

### 3.1 Non-secret: `app_environment` in `prod.tfvars`

- A `KEY = "value"` map that appears verbatim in the task definition, with the comment pattern of
  [08](../../docs/08-infrastructure.md) §3.1.
- **Infrastructure-derived values** (Typesense private IP, error tracker table/log group names) are computed by Terraform
  as defaults (`derived_environment`) and then `merge`d with `app_environment` (tfvars wins when set).

### 3.2 Secrets: `app_secret_keys` → SSM Parameter Store

- `prod.tfvars` holds only the secret **names**. Each name maps to an SSM SecureString parameter
  `<ssm_parameter_prefix>/<NAME>` (e.g. `/<project>/prod/JWT_API_SECRET`) that the ECS agent pulls when the container
  starts (`secrets[].valueFrom`).
- Fill in the values with `scripts/put-secrets.sh <env-file>`; values > 1 KB (service account JSON, base64 certificates)
  are filled in **from a file**, not through interactive input (the terminal truncates long lines without telling you).
- **Fill in the SSM parameters BEFORE the change reaches `main`.** CI applies right away, and a task that references a
  parameter that does not exist yet fails to start.
- The Typesense API key is created by Terraform from one variable for both the server and SSM, so the two can never
  differ.
- The execution role has `ssm:GetParameters` on that prefix + `kms:Decrypt` with a `kms:ViaService` condition.
- SSM is the source of truth for every credential; a local copy (an env file on an operator machine) can be stale.

---

## 4. ECS, ALB, network

### 4.1 Cluster & hosts

- The hosts run the **ECS-optimized Amazon Linux arm64 AMI** (the ECS agent and Docker baked in), read from the public SSM
  parameter `/aws/service/ecs/optimized-ami/amazon-linux-2/arm64/recommended/image_id`.
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
- **`deployment_circuit_breaker { enable = true, rollback = true }` on BOTH services** — the incident behind it is in
  [08](../../docs/08-infrastructure.md) §4.2.
- **Task definitions change only through Terraform.** Values changed in the console do not enter the state and are
  overwritten by the next apply (this once put the API and the worker into a crash loop).
- The ECS `stopTimeout` defaults to 30 s: a worker that waits for its running tick must finish within it
  ([05](../../docs/05-workers-and-integrations.md) §1.4).

### 4.3 ALB

- Public subnets in 2 AZs; HTTPS 443 listener with `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` and a
  **Cloudflare Origin Certificate** imported into ACM by hand (the private key never enters Terraform
  state; ACM does not renew imported certificates — use a long validity, 15 years).
- HTTP 80 listener → 301 redirect to 443.
- HTTP target group to the container port (e.g. 8000), health check `GET /health`, matcher `200-399`, interval 30,
  healthy/unhealthy threshold 3.
- **The ALB security group only accepts 443 from Cloudflare IP ranges** (data source `cloudflare_ip_ranges`, IPv4 +
  IPv6). Consequence: DNS records must be **proxied**; DNS-only mode or SSL "Flexible" (Cloudflare to the origin over
  port 80) takes the whole site down with 521/522. Because of that data source, the Cloudflare token is needed as early
  as `plan`.
- The ALB idle timeout is 60 s, so the application's `HTTP_IDLE_TIMEOUT` is 120 s
  ([02](../../docs/02-database.md) §6.2).

### 4.4 Network

- A `/16` VPC, two public subnets (ALB, NAT) and two private subnets (ECS hosts, Typesense) across two AZs.
- One NAT Gateway (EIP, `prevent_destroy`) in AZ a; private routes go through the NAT. The NAT's public IP is stable → it
  restricts server-side third-party API keys (e.g. a Google Maps server key restricted to the NAT IP) and sits in the
  payment gateway's IP allowlist.
- **The VPC is IPv4-only.** Supabase's direct-connection host only has an AAAA record, so it cannot be reached
  (`connect: cannot assign requested address`, panic at boot; the API and the worker both die because the connections are
  opened before the mode branch). The fix is the pooler host, which has an A record
  ([02-postgres-on-supabase.md](02-postgres-on-supabase.md) §2).

### 4.5 Typesense on EC2

- Amazon Linux 2023 arm64 AMI, private subnet a; user data installs & runs Typesense in Docker with the API key from a
  Terraform variable; `ignore_changes = [ami]` so the instance is not replaced on every new AMI.
- **A separate encrypted EBS data volume** (`aws_ebs_volume` + attachment) so the data survives when the instance is
  replaced.
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

### 4.7 SES (email)

Infrastructure:

- SES domain identity + DKIM + custom MAIL FROM; DNS records created by Terraform in Cloudflare: TXT verification, three
  DKIM CNAMEs (**not** proxied), MAIL FROM MX + SPF, root SPF, DMARC `p=quarantine` (+ optional `rua`).
- A new SES account = **sandbox** (200 emails/day, verified addresses only). Request production access from day one,
  before email is used for user verification. Leaving the sandbox is an AWS support ticket, not Terraform.

The email channel of [05](../../docs/05-workers-and-integrations.md) §3.5, on SES:

- `sesv2.SendEmail` with `Content.Simple` (Subject + Text + Html, UTF-8), From `"<Q-encoded Name> <no-reply@<domain>>"`.
- Credentials come from the ECS **task role** (the access key pair is **left empty** on AWS). SES has **its own client**:
  the process's `aws.Config` built for R2 (region `auto`) fails every send with symptoms that look like "an IAM problem".
- Narrow classification: only `MessageRejected` = permanent; throttling, quota, paused account, unverified identity =
  retryable.
- SES has no idempotency token → `EmailTags: delivery_uuid=<idempotency_key>` for bounce correlation;
  `SES_CONFIGURATION_SET` once bounces/complaints are wired to SNS.
- IAM `ses:SendEmail` only, resource = the domain identity + `identity/*@<domain>` in the sending region (restricts the
  From address). `SES_REGION` = the Terraform region variable that forms the ARN.
- Env: `SES_REGION`, `SES_FROM_ADDRESS` (required), `SES_FROM_NAME`, `SES_CONFIGURATION_SET`, `EMAIL_SINK_DIR` (local
  only).

Monitoring (the CloudWatch dashboard, the error tracker's DynamoDB table) is in
[04-observability-on-aws.md](04-observability-on-aws.md).

---

## 5. Application image: `linux/arm64`

The [Dockerfile template](../../templates/backend/Dockerfile) as is, built for the Graviton hosts:

- **Platform `linux/arm64` is mandatory here.** An amd64 image pushes to ECR without complaint and then dies at runtime
  with `exec format error`.
- Build on a **native arm64** runner (`ubuntu-24.04-arm`); a Go build under QEMU emulation takes 20–40 minutes.
- The ECS `command` overrides `CMD`, not `ENTRYPOINT`, so the task definition only needs the subcommand (`["main"]`,
  `["worker"]`). The real configuration comes from ECS as env; the image ships an empty `.env`.

---

## 6. Backend deploy (`.github/workflows/deploy.yml`)

Template: [templates/deploy.yml](templates/deploy.yml).

- **Only `workflow_dispatch`**: `gh workflow run deploy.yml --ref master` (the reason is in
  [08](../../docs/08-infrastructure.md) §6).
- `permissions: { id-token: write, contents: read }`; `concurrency: { group: deploy-prod, cancel-in-progress: false }`
  (two deploys never race).
- Steps: checkout → compute `short_sha` and `build_time` → AWS OIDC (`AWS_DEPLOY_ROLE_ARN`) → ECR login → buildx →
  `docker/build-push-action` (`platforms: linux/arm64`, `provenance: false`, tags `:latest` + `:<short_sha>`,
  build-args `TOKEN`, `GIT_SHA`, `BUILD_TIME`, cache `type=gha`) → `aws ecs update-service --force-new-deployment`
  for the API and worker services → rollout state report → summary in the step summary.
- One run takes ±3 minutes.
- **Last deployed SHA** = `headSha` of the last successful run of `deploy.yml`; compare it with `origin/master` before
  pressing deploy.

### 6.2 Verifying the rollout on AWS

1. `gh run watch <id> --exit-status` in the foreground (a background notification once arrived while the run was still
   building).
2. `aws ecs wait services-stable --cluster <cluster> --services <api> <worker>`; rollout state `COMPLETED`.
3. Compare the `imageDigest` of every running task with the ECR digest of the `<short_sha>` tag.
4. Read the `/ecs/<prefix>/api` and `/ecs/<prefix>/worker` log groups: the build line (`revision` = the new SHA), no new
   ERROR/panic, the cache lease taken by the new build.
5. Probe the public API (unknown route → 404, admin route without a token → 401, the feature's main flow); record it in
   the deploy log.

### 6.3 Rollback on AWS

- **Faulty feature:** turn off its switch in `prod.tfvars` → push to `main` → CI applies.
- **Faulty binary:** run `deploy.yml` from the previous ref (`--ref <branch/tag>`, or a revert on master). The ECS circuit
  breaker already handles revisions that never become healthy.

---

## 7. Commands as one-off ECS tasks

Production commands (backfill, purge, retry) run as **one-off ECS tasks** from the worker task definition with a `command`
override (`["command","<name>","--dry-run"]`), or from an operator machine with the production env. Both use the same
pooler connection budget ([02-postgres-on-supabase.md](02-postgres-on-supabase.md) §5).

---

## 8. Changing infra

1. Branch in the infra repo; change `prod.tfvars`/modules.
2. **Run a read-only local plan first** (`terraform plan -lock=false -var-file=prod.tfvars`; without a Cloudflare token:
   `-refresh=false` + a 40-character dummy token). The plan may contain only your changes (+ the known launch template
   AMI drift, §4.1).
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
  see [03-cloudflare.md](03-cloudflare.md)).

---

## 9. Setup from scratch on AWS

The provider-neutral order is [11-checklists.md](../../docs/11-checklists.md) §A. On AWS:

1. A dedicated AWS account for the project + a named CLI profile (do not use `default` if the laptop has other accounts).
2. Collect the external values: Cloudflare token (Zone DNS Edit, restricted to the zone), zone ID, Origin Certificate → ACM,
   SSL mode Full (strict), Typesense API key (`openssl rand -hex 32`).
3. Apply `bootstrap/` (state bucket, lock table, OIDC + roles).
4. Fill in `prod.tfvars` (non-secret) and `terraform.tfvars` (local secrets); run the first apply from a laptop.
5. Push the first image (`docker buildx build --platform linux/arm64 … --push`); the services come up on their own.
6. Fill in the GitHub Secrets (`AWS_TERRAFORM_ROLE_ARN`, `CLOUDFLARE_API_TOKEN`, `TF_VAR_*`) in the infra repo, and
   (`AWS_DEPLOY_ROLE_ARN`, `GOPRIVATE_TOKEN`) in the backend repo.
7. Fill in SSM with `put-secrets.sh`, then run `deploy.yml`.
