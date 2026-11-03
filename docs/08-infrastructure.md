# 08 — Infrastructure & backend deploy

What the backend's production infrastructure must provide, and how a backend release is shipped, verified, and rolled
back. Pakem does not choose the cloud, the container platform, the CPU architecture, or the managed services: those are
the project's decisions, recorded in its `AGENTS.md`. The requirements below hold whichever products are chosen. One
concrete implementation is the [case study](../case-studies/aws-supabase-cloudflare/01-backend-on-aws.md); its sections
follow the numbering of this chapter.

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Topology

Every box is a **role**; the product that fills it is the project's choice.

```
Internet
   │
Edge / DNS proxy (TLS verified end to end)                      ← 09-frontend-and-storage.md
   │  api.<domain>  (proxied)
   ▼
Load balancer  (TLS; accepts traffic only from the edge; health check GET /health)
   ▼
Container platform (private network)
   ├── service <prefix>-api     : app image, command ["main"],   autoscaled on CPU, behind the load balancer
   └── service <prefix>-worker  : app image, command ["worker"], 1 instance, no load balancer
   │
Private network
   ├── search engine (its data on a persistent volume) — reachable only from the application hosts
   └── egress through ONE fixed IP (NAT)
   │
Outside the private network (managed or self-hosted):
   ├── PostgreSQL behind a connection pooler                    ← 02-database.md §6
   ├── Redis (single node, ≥ 6.2)                               ← 04-caching.md §1
   ├── object storage (S3 API)                                  ← 09-frontend-and-storage.md §4
   ├── transactional email provider                             ← 05-workers-and-integrations.md §3.5
   ├── log store + the error tracker's store                    ← 06-observability.md
   └── third-party services (payment gateway, messaging, push, OAuth providers, …)
```

**Requirements** (keep them unless there is a strong, recorded reason):

- **One image for the API and the worker**; the only difference is the command.
- **Two services with different rollout settings** (§4.2): the API scales and rolls; the worker runs as one instance.
- **The search engine keeps its data across a host replacement** (a persistent volume, or a managed service) and is not
  reachable from the internet.
- **One fixed egress IP** — third parties allow-list it, and server-side API keys are restricted to it.
- **One production environment.** There is no mandatory backend staging: validation is done with local E2E against the
  production schema/dump, followed by a staged rollout in production behind feature switches
  ([07-testing-and-e2e.md](07-testing-and-e2e.md), [10-workflow.md](10-workflow.md)).
- **One dedicated cloud account (or project) per product.** Do not piggyback on another product's account; the
  infrastructure code pins the account so an apply with the wrong credentials fails fast.

Starting settings proven sufficient for a small-to-medium SaaS:

| Component | Value |
|---|---|
| API service | autoscaling 1–4 instances, CPU target 70%, scale-out cooldown 60 s, scale-in 300 s |
| Worker service | 1 instance, no autoscaling |
| Region | one region close to the users |
| Logs | one log group/stream per service (API, worker), 30-day retention |

Host sizes are a choice of the platform; the case study lists the ones it ran
([overview](../case-studies/aws-supabase-cloudflare/README.md) §4).

All resource names use the prefix `<project>-<environment>` (e.g. `<project>-prod-api`, `<project>-prod-worker`,
`<project>-prod-app` for the image repository).

---

## 2. Infra repo (infrastructure as code)

All infrastructure and DNS live in **code** (Terraform, OpenTofu, Pulumi, …) in a separate repo, `<project>-prod-infra`,
laid out by concern:

```
bootstrap/            # run ONCE by a human, LOCAL state
                      #   remote state storage (versioned, encrypted, private) + its lock
                      #   CI identity federation + the IaC CI identity + the backend deploy identity
<root>/               # the root stack, remote state, run by CI
  settings (committed)  # every non-secret setting: one source of truth for local runs & CI (§3.1)
  secrets (gitignored)  # secrets for local runs only
  modules/
    networking/       #   network, public/private subnets in 2 zones, one NAT with a fixed IP, routes
    security/         #   firewall rules + runtime identities (host, execution, application)
    registry/         #   one image repository (API + worker share the image)
    compute/          #   hosts/cluster, the two services, the search engine host, log groups, the error tracker store
    load_balancer/    #   load balancer, target group, listeners
    email/            #   email provider domain identity + DKIM + MAIL FROM
    dns/              #   DNS records (api → load balancer, email records)
    monitoring/       #   dashboard (load balancer, services, capacity)
scripts/
  load-env.sh         #   selects the cloud profile + fetches the DNS provider token, then verifies both
  put-secrets.sh      #   fills the secret store from an env file (values are not printed)
<CI workflow>         #   plan on PRs, apply on main (§2.2)
README.md SETUP.md    #   architecture + setup order from scratch (the chicken-and-egg problem explained)
<version file>        #   pinned IaC tool version
```

### 2.1 Why `bootstrap/` exists

Two circular dependencies:

1. **CI needs the remote state storage, and the storage is created by the infrastructure code** → `bootstrap/` uses local
   state to create the storage + its lock (both protected from deletion).
2. **CI needs a cloud identity, and the identity is created by the infrastructure code** → the CI identities are created
   by a human with admin credentials, in `bootstrap/`.

| Directory | Run by | Frequency | State |
|---|---|---|---|
| `bootstrap/` | A human, from a laptop | Once in a lifetime (and when adding an identity) | Local (gitignored, contains no secrets) |
| `<root>/` | CI (plan on PRs, apply on `main`) | Every change | Remote |

### 2.2 Infra CI

- Watches only the root stack and the workflow file itself.
- **PR:** format check → init → validate → plan with the committed settings file.
- **Push to `main`:** apply with the committed settings file, bound to a protected CI environment (`production`; add a
  required reviewer if you want a manual gate).
- Cloud credentials through **federation** (OIDC from the CI provider), **no static access keys**.
- The only CI secrets: the identity to assume, the DNS provider token, and the IaC secret variables.
- **The IaC tool version is pinned in two places** (the version file and the CI workflow). A newer version can upgrade the
  state format, and the older CI version then refuses to read it. Upgrading = change both at once.

### 2.3 CI identity federation

- One OIDC trust between the CI provider and the cloud.
- **The trust condition (the token's `sub` claim) MUST** restrict each identity to specific repos. Without it, any repo on
  the CI provider can take over the identity. When the CI provider can put immutable identifiers in the claim, allow both
  spellings.
- **Identity 1 — IaC CI (infra repo):** broad within each managed service, **locked to one region**; creating identities
  only under the stack prefix (`<project>-<env>-*`); handing roles only to the platform's own services; access to the
  state storage + lock; the application's tables.
- **Identity 2 — deploy (backend repo):** push to **one** image repository, roll **the two** services, and read their
  state. **No permission to change service definitions:** those belong to the infrastructure code (§4.2).

---

## 3. Application configuration

The API and the worker are the same binary, so they receive **identical** configuration, assembled **once** in the
infrastructure code and used by both service definitions.

### 3.1 Non-secret settings, committed with their reasons

- A `KEY = "value"` map in the committed settings file that appears verbatim in the service definitions. It **must not**
  contain passwords, tokens, or keys.
- Every key gets a comment: what it means, its default in the code, when and with whose approval its value is changed,
  its prerequisites, and how to roll it back. That comment is operational documentation (example below).
- **Infrastructure-derived values** (the search engine's private address, the error tracker's table/log group names) are
  computed by the infrastructure code as defaults and merged with the map (the committed value wins when set).
  Do not copy addresses/names by hand: a copied value is bound to go stale without anyone noticing.
- Keys that have no value yet are **commented out**, not `KEY = ""` (an empty string overrides `.env` — godotenv checks
  whether a key exists, not what it contains).

Example of the feature-switch comment pattern (HCL shown; the pattern is the comment, not the syntax):

```hcl
  # ---- Marketplace ----
  # Public provider directory: GET /marketplace/listings… and the marketplace-listings worker.
  # Off = both endpoints 404 and no account is queued.
  # Turned on <date> with the user's OK, after migration NNN and backend deploy <sha>.
  # After apply: run the backfill-marketplace-listings command once.
  MARKETPLACE_ENABLED = "true"
```

### 3.2 Secrets in a secret store

- The committed settings hold only the secret **names**. Each name maps to an encrypted entry
  `<prefix>/<NAME>` (e.g. `/<project>/prod/JWT_API_SECRET`) in the platform's **secret store**, injected as env when the
  container starts.
- Fill in the values with `scripts/put-secrets.sh <env-file>`; values > 1 KB (service account JSON, base64 certificates)
  are filled in **from a file**, not through interactive input (the terminal truncates long lines without telling you).
- **Fill in the secret store BEFORE the change that references a secret reaches `main`.** CI applies right away, and a
  container that references a secret that does not exist yet fails to start.
- Secrets used by both a server and the application (e.g. the search engine's API key) are created by the
  infrastructure code from one variable, so the two can never differ.
- Secrets the code no longer reads are removed from the list (record the reason in a comment).
- Only the identity that starts containers can read that prefix (§4.6). The secret store is the source of truth; local
  copies can be stale.

### 3.3 Kill switches and prerequisites

Switches that turn a channel/feature on are written explicitly in the committed settings, **with their prerequisites**:

- A switch that depends on new code: **deploy the backend first, then apply** (an old image + a new switch can
  bring the process down).
- A switch that depends on a secret: **fill in the secret store first, then apply**.
- A worker started without a name runs **all** workers in one process; a channel configuration validation that fails at
  start (`os.Exit(1)`) brings down the **whole** worker (email dies with it). Therefore: validation fails → turn off only
  that channel, or make sure the configuration is valid before the switch is turned on.
- Turning a switch off (`"false"`) is an **instant rollback with no deploy and no data change** — this is why
  every risky feature gets a switch.

---

## 4. Container platform, load balancer, network

### 4.1 Hosts

When the platform runs containers on hosts you manage:

- Use the platform's **maintained host image** (its agent and container runtime baked in), read from the reference the
  platform publishes, not a hand-built image.
- Require the hardened, token-based instance metadata service; keep hosts in private subnets; protect hosts that run
  containers from scale-in.
- Know what an apply does to hosts. If every apply picks up the newest host image, record that this drift is routine and
  that running hosts are only replaced by a scale-out or a planned refresh — otherwise every plan looks alarming.

### 4.2 Services & rollout

- A deploy changes **the image, never the service definition**: both services run the moving tag `latest` (the
  `<short_sha>` tag pins what ran), and the deploy only starts new instances with the new image.
- **API service:** rolling with minimum healthy 50% / maximum 200% (it rolls even on a single host without a deadlock),
  autoscaling on average CPU, and the infrastructure code ignores the live instance count.
- **Worker service:** one instance, minimum healthy 0% / maximum 100% (the old instance may stop before the new one is
  healthy — never two worker sets at the same time).
- **A deployment circuit breaker with automatic rollback on BOTH services.** Incident lesson: a new revision panicked at
  boot (wrong DB host) and failed over and over, the rollout stayed in progress, and traffic was served by old-revision
  instances that happened not to have restarted yet — the API looked healthy while its new revision was in a crash loop.
  The worker failed 146 times without anyone noticing. The circuit breaker stops the attempts and returns to the last
  healthy revision.
- **Service definitions change only through the infrastructure code.** Values changed in a console do not enter the
  state and are overwritten by the next apply (this once put the API and the worker into a crash loop).
- Know the platform's stop timeout (often 30 s): a worker that waits for its running tick must finish within it
  ([05-workers-and-integrations.md](05-workers-and-integrations.md) §1.4).

### 4.3 Load balancer

- HTTPS with a modern TLS policy (TLS 1.2+, 1.3 preferred); HTTP → 301 to HTTPS.
- The certificate is the **edge provider's origin certificate** (or another certificate the edge verifies), installed by
  hand so its private key never enters the infrastructure state; when the platform does not renew an imported
  certificate, use a long validity and record the expiry date.
- Health check `GET /health`, matcher `200-399`, interval 30 s, healthy/unhealthy threshold 3. **Make sure the container
  port and the health check path match the application** (it was once set to 8080 while the application listened on
  8000 — the health check never passed).
- **The load balancer only accepts traffic from the edge's published IP ranges.** Consequence: DNS records must be
  **proxied**; switching the proxy off, or letting the edge reach the origin over plain HTTP, takes the whole site down.
  Read the ranges from the edge provider at plan time, never from a hand-copied list.
- The application's HTTP idle timeout must be **longer** than the load balancer's
  ([02-database.md](02-database.md) §6.2).

### 4.4 Network

- Two public subnets (load balancer, NAT) and two private subnets (application hosts, search engine) across two zones.
- **One NAT with a fixed public IP**, protected from deletion; private routes go through it. That IP restricts
  server-side third-party API keys (e.g. a maps server key restricted to the egress IP) and sits in allow-lists at third
  parties (a payment gateway).
- **Check IP-family reachability before the first deploy.** An IPv4-only network cannot reach a host that only has an
  AAAA record (`connect: cannot assign requested address`, panic at boot; the API and the worker both die because the
  connections are opened before the mode branch). Use an endpoint that has an A record (for the database: the pooler,
  [02-database.md](02-database.md) §6.1).

### 4.5 Search engine host

- Its data on a **separate persistent volume**, so the data survives when the host is replaced; replacing the host image
  must not replace the host on every apply.
- Reachable only from the application hosts; inside the private network TLS is optional.
- Its address is **derived by the infrastructure code** (it changes whenever the host is replaced); its API key is one
  variable for the server and the secret store (§3.2).
- Admin access through the platform's session manager, not open SSH.
- One pinned version, the same in production and locally ([05-workers-and-integrations.md](05-workers-and-integrations.md) §4.4).

### 4.6 Runtime identities

| Identity | May |
|---|---|
| Host | run the platform's agent; be reached through the session manager |
| Execution (starts containers) | pull the image; read **only** the application's secret prefix (and decrypt it) |
| Application | send email **only** from the product's domain; item operations on the error tracker's table; read the application's own log groups |

Where the platform offers it, the application calls provider SDKs **with its runtime identity**, not with a static key
pair in env or the secret store.

### 4.7 Email domain, monitoring

- The email provider's domain identity + DKIM + a custom MAIL FROM; the DNS records come from the infrastructure code:
  verification, DKIM (**not** proxied), MAIL FROM MX + SPF, root SPF, DMARC `p=quarantine` (+ optional `rua`).
- A new email account often starts in a **sandbox** (low daily limit, verified recipients only). Leave it before email
  is used for user verification — from day one.
- A dashboard from the infrastructure code for the load balancer (requests, 5xx, latency), the services (CPU/memory,
  running vs desired), and capacity ([06-observability.md](06-observability.md) §7).
- The error tracker's store: deletion protection on (it holds the recipient list & statuses filled in by admins). See
  [06-observability.md](06-observability.md) §4.

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
  comes from the platform as env); `EXPOSE <port>`; `ENTRYPOINT ["/<dir>/<app>"]`, `CMD ["main"]`. The service's
  command overrides `CMD`, not `ENTRYPOINT`, so the service definition only needs the subcommand (`["main"]`,
  `["worker"]`).
- `.dockerignore`: `.git` (the remote URL may contain a PAT), `.env*`, `app/mocks`, `**/*_test.go`, `scripts`, `docs`,
  `.github`, local binaries.
- **The image's platform MUST match the hosts' CPU architecture** (amd64 or arm64 — the project's choice). A mismatched
  image pushes without complaint and then dies at runtime with `exec format error`. Build on a **native** runner for that
  architecture: a Go build under emulation takes 20–40 minutes.

---

## 6. Backend deploy

A CI workflow in the backend repo. The case study's [`deploy.yml`](../case-studies/aws-supabase-cloudflare/templates/deploy.yml)
is one implementation.

- **Manual trigger only** — on purpose. An automatic deploy on every push to `master` makes `master` unusable for
  holding changes that are not ready for release, for combining several merges into one rollout, or for late-night
  merges. Production moves when someone decides it does (e.g. `gh workflow run deploy.yml --ref master`).
- Least privilege (a federated token + read access to the code); **one deploy at a time** (a concurrency group that never
  cancels a running deploy).
- Steps: checkout → compute `short_sha` and `build_time` → federated login → registry login → build for the hosts'
  platform (tags `:latest` + `:<short_sha>`, build args `TOKEN`, `GIT_SHA`, `BUILD_TIME`, a build cache) → push →
  **start a new deployment of the API and worker services** (the service definitions do not change) → rollout state
  report → summary.
- A run should take minutes (±3 in the case study).

### 6.1 Before pressing deploy

1. `git fetch`; compare the **last deployed SHA** (the commit of the last successful deploy run) with `origin/master` — a
   deploy ships master's HEAD, so make sure no one else's unready work ships along with it.
2. The migrations the new code needs **have already been run** in production (expand first, see
   [02-database.md](02-database.md)), with the user's approval.
3. New secrets are already in the secret store; feature switches are still off (or their prerequisites are met).
4. Take the **deploy lock** if there are several sessions/agents ([10-workflow.md](10-workflow.md)).

### 6.2 Verifying the rollout

1. Wait for the run to finish **in the foreground** (e.g. `gh run watch <id> --exit-status`; a background notification
   once arrived while the run was still building — do not report "deployed" before checking it directly).
2. Wait until **both services are stable** and the rollout is complete.
3. Compare the **image digest of every running instance** with the registry digest of the `<short_sha>` tag.
4. Read the API and worker logs: the build line (`revision` = the new SHA), no new ERROR/panic, the cache lease taken by
   the new build.
5. Probe the public API: unknown route → 404, admin route without a token → 401 (proves the new routes are live), and
   the feature's main flow.
6. Record it in the deploy log (SHA, run id, time, migrations, switches).

### 6.3 Rollback

- **Faulty feature:** turn off its switch (infra apply) — fastest, no data change.
- **Faulty binary:** run the deploy from the previous ref/SHA (a branch/tag, or a revert on master); the circuit breaker
  already handles revisions that never become healthy.
- **Migration:** the expand/contract design keeps the old binary working on the new schema; do not roll back the schema
  unless you have no other choice, and only with approval.
- The cache has its own rollback rules (generation/lease/epoch): [04-caching.md](04-caching.md) §Operations.

---

## 7. Commands as one-off tasks

Production commands (backfill, purge, retry) run as **one-off tasks** from the worker's service definition with a command
override (`["command","<name>","--dry-run"]`), or from an operator machine with the production env — both use the same
pooler connection budget, so count them within the pool limits ([02-database.md](02-database.md)).
Always `--dry-run` first, report how much will change, and ask for approval if it is destructive (deletes/overwrites data).

---

## 8. Changing infra

1. Branch in the infra repo; change the settings/modules.
2. **Run a read-only local plan first** (no state lock; when a provider token is missing, skip the refresh and pass a
   dummy token of the right shape). The plan may contain only your changes (+ any known, routine drift, §4.1).
3. Fill in the secret store for new secrets.
4. Merge/push to `main` → CI applies. **An infra apply redeploys the services** when a service definition changes: treat
   it as a deploy (deploy lock, rollout verification).
5. State locked because an apply was killed: force-unlock it, after making sure no other apply is running.

### 8.1 Common problems

| Symptom | Usual cause |
|---|---|
| IaC init fails, the remote state does not exist | `bootstrap/` has not been run / the storage name does not match |
| A service keeps restarting | image not in the registry yet, wrong CPU architecture, DB host unreachable, a secret that does not exist yet |
| Load balancer 502/503 | unhealthy targets: container port / health check path mismatch |
| The edge cannot reach the origin | record not proxied, or TLS to the origin not verified end to end |
| A provider error during plan | the provider token was not exported (e.g. needed to read the edge's IP ranges) |
| CI rejects the state | the local IaC version is newer than CI's |
| CI apply fails the DNS provider's authentication | the token expired (create an infra token that never expires, or record its expiry date) |

### 8.2 Things deliberately not managed by the infrastructure code

- The origin certificate's private key → installed by hand.
- Image build & push → the application repo's pipeline.
- Provider support requests (e.g. leaving an email sandbox).
- Services managed in their own console or CLI (the database host, the Redis host, frontend hosting, object storage, the
  edge) — each gets a runbook ([09-frontend-and-storage.md](09-frontend-and-storage.md)).

---

## 9. Setup from scratch (short)

The full sequence is in [11-checklists.md](11-checklists.md) §Bootstrap. The essentials:

1. A dedicated cloud account for the product + a named CLI profile (do not use `default` if the laptop has other accounts).
2. Collect the external values: the DNS provider token (DNS edit, restricted to the zone), the zone ID, the origin
   certificate, TLS verified end to end, the search engine API key (`openssl rand -hex 32`).
3. Apply `bootstrap/` (state storage, lock, federation + identities).
4. Fill in the committed settings (non-secret) and the local secrets file; run the first apply from a laptop.
5. Push the first image (built for the hosts' platform); the services come up on their own.
6. Fill in the CI secrets: the IaC identity, the DNS provider token, and IaC secret variables in the infra repo; the deploy
   identity and `GOPRIVATE_TOKEN` in the backend repo.
7. Fill in the secret store with `put-secrets.sh`, then run the deploy workflow.
