# Case study 03 — Frontend, edge, files, and DNS on Cloudflare

An illustration, not part of the standard: how the [case study](README.md) deployment met
[09-frontend-and-storage.md](../../docs/09-frontend-and-storage.md) on Cloudflare. Its decision was that everything the
browser sees and every user file lives on Cloudflare, while the backend lives on AWS
([01-backend-on-aws.md](01-backend-on-aws.md)).

| Need | Cloudflare service |
|---|---|
| DNS for all domains, proxy + TLS for the API | DNS + proxy (orange cloud), SSL **Full (strict)** |
| User web app (SPA) | **Cloudflare Pages** (Git integration) |
| Internal/admin dashboard (SPA) | **Cloudflare Pages** (separate project) |
| Small server-side logic owned by the frontend | **Pages Functions** (only on the paths that need them) |
| SEO/Open Graph for bots, alias domains | a **Cloudflare Worker** "edge" in front of Pages |
| User files & public assets | **R2** (public bucket behind a CDN custom domain; private bucket through presigned URLs) |
| Rate limits at the edge (recommended in [03](../../docs/03-api-design.md) §6.4) | a rate-based **WAF** rule in front of login/register/public writes |

---

## 1. Domain map

| Host | Points to | Managed by |
|---|---|---|
| `<domain>` | edge Worker `<project>-edge-main` (custom domain) → Pages `<project>-fe-main` | Dashboard/wrangler |
| `staging.<domain>` | edge Worker `<project>-edge-staging` → Pages `<project>-fe-staging` | wrangler (`custom_domain = true`) |
| `api.<domain>` | CNAME → ALB, **proxied** | Terraform (`cloudflare` module) |
| `cdn.<domain>` | custom domain of the public R2 bucket | R2 dashboard |
| `internal.<domain>` | Pages `internal-dashboard` (production branch) | Pages dashboard |
| short/alias domains (optional) | zone route of the edge Worker (bots: the page; browsers: 301 to `<domain>`) | wrangler (`routes` in `[env.main]`) |
| email records (SES) | verification, DKIM (not proxied), MAIL FROM, SPF, DMARC | Terraform |

- A hostname can belong to only **one** Worker/custom domain at a time; detach it from the old target before attaching
  it to the new one (Cloudflare answers "already assigned to another service").
- **SSL/TLS mode Full (strict)** on the zone. The API behind the ALB uses a Cloudflare Origin Certificate and the ALB SG
  only accepts Cloudflare IPs — the API record must be proxied ([01-backend-on-aws.md](01-backend-on-aws.md) §4.3).

---

## 2. Cloudflare Pages

### 2.1 Deploy pattern

- **Pages Git integration, no GitHub Actions in the FE repo.** A push to the production branch (e.g. `main` for the web app,
  `master` for the internal dashboard) = a production deploy within ±1–3 minutes. Other branches get a `*.pages.dev`
  preview.
- Two projects per app when staging hosting is needed: `<project>-fe-main` and `<project>-fe-staging` (branch
  `staging`). The FE staging may point to the production API or be turned off.
- The deploy status shows up as a GitHub check run "Cloudflare Pages: <project>" on the **full SHA** (a short SHA answers
  422). A fast-forward to a SHA that already had a preview build leaves the old check run in place — wait for a **new**
  run (`started_at` after the push).
- Old deploy integrations that are no longer used (S3/CloudFront, Vercel) were removed so false red statuses could not
  hide the real status.

### 2.2 Configuration

- Secrets for Pages Functions are stored as **encrypted environment variables in the Pages dashboard**, not in the repo.
- SPA fallback is handled by Pages; dynamic routes that need different HTML for bots are handled by the edge Worker or a
  Function.

### 2.3 Pages Functions — only on the paths that need them

`functions/` in the FE repo + a `public/_routes.json` that **limits** which paths invoke a Function; everything else is
static assets/SPA fallback without a Function invocation (faster, no invocation cost):

```json
{
  "version": 1,
  "description": "Functions only where needed: proxy (/api/*), event link preview (/*/event/*), Apple Sign-in return (/log-in).",
  "include": ["/api/*", "/*/event/*", "/log-in"],
  "exclude": []
}
```

Local test: `npx wrangler pages dev dist --port 8788 --compatibility-date=<date>`.

### 2.4 Internal/admin dashboard

A separate SPA repo and a separate Pages project, host `internal.<domain>`. Same deploy pattern (push to the production
branch = deploy).

---

## 3. The edge Worker in front of Pages

Repo `<project>-edge`: a JavaScript Worker (ES Modules) that behaves like Lambda@Edge in front of Pages, implementing
[09](../../docs/09-frontend-and-storage.md) §3.

```
Internet → Worker (router → isbot?)
             │ browser / static assets        │ bot + profile page (/:username, /@:username)
             ▼                                 ▼
        Pages origin (SPA as is)            Cache API (300 s) ── miss ──► Promise.all(
                                                                         fetch Pages HTML,
                                                                         fetch public backend API)
                                                                       → build metadata
                                                                       → HTMLRewriter injects into <head>
                                                                       → cache + return HTML
```

- Bots get the same Pages HTML with SEO/OG/Twitter tags injected through **`HTMLRewriter`**.
- A Worker cannot service-bind to Pages: it `fetch`es `PAGES_ORIGIN` (`<project>-fe-main.pages.dev`). There is no loop as
  long as the `PAGES_ORIGIN` hostname differs from the Worker's hostname.
- **Two environments, one repo** (`wrangler.toml`): `[env.staging]` and `[env.main]` with different Worker names.
  **`[vars]` is not inherited by environments** — every `[env.*.vars]` block must repeat all variables (a forgotten
  variable shows up as `undefined` at runtime, not as a deploy error).
- **Deploy:** `npx wrangler deploy --env main --tag <sha> --message "<summary>"` (or `npm run deploy:main`). Workers
  Builds (auto-deploy from Git) is set up per Worker in the dashboard and can only be attached to a Worker that already
  exists — make sure the branch → Worker mapping is right; otherwise a push can ship staging variables to production.
  Keep the edge repo's `main` and `staging` branches in sync with what is live.
- **Testing:** `curl -A "Slackbot-LinkExpanding 1.0" "https://<domain>/<user>?cb=$RANDOM"`, then check the header
  `x-edge-rendered: bot`, `og:url`, `og:image`. The Cache API key does not depend on the host (prod & staging can serve
  each other's cached bot HTML for 300 s) → always use a cache-buster.
- Local test: `wrangler dev` with a `.dev.vars` that points `PAGES_ORIGIN` at a static server for `dist/` (SPA fallback)
  and `API_BASE_URL` at the local backend.

---

## 4. R2

### 4.1 Buckets

| Bucket | How it is read |
|---|---|
| Public (assets) | public URL `ASSET_PUBLIC_BASE_URL` = the R2 custom domain (`https://cdn.<domain>`) |
| Private (sensitive documents) | **only** short-lived presigned GETs, created by the backend after an access check |

- R2 credentials (an access key pair per bucket/app, never a full-account token) live in SSM; SSM is the source of truth,
  local copies can be stale.
- Env names follow the provider that issues the key: `CLOUDFLARE_ACCESS_KEY_ID` / `CLOUDFLARE_SECRET_ACCESS_KEY`, plus
  `R2_ENDPOINT`, `R2_REGION`, `R2_BUCKET`, `R2_PRIVATE_BUCKET`, `ASSET_PUBLIC_BASE_URL`.

### 4.2 Backend client

R2 speaks the S3 API, so the backend uses `aws-sdk-go-v2/service/s3` ([09](../../docs/09-frontend-and-storage.md) §4.2):

```go
// app/cmd/connection.go
func r2Configuration(cfg config.Configuration) aws.Config {
    optFns := func(o *awsConfig.LoadOptions) error {
        o.Region = cfg.R2.Region // "auto"
        o.Credentials = credentials.StaticCredentialsProvider{Value: aws.Credentials{
            AccessKeyID: cfg.Cloudflare.AccessKeyID, SecretAccessKey: cfg.Cloudflare.SecretAccessKey}}
        // R2 does not implement the flexible checksum trailers the SDK now adds by default;
        // only when required → presigned PUTs stay valid.
        o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
        return nil
    }
    c, err := awsConfig.LoadDefaultConfig(context.TODO(), optFns)
    if err != nil { log.Panic(err) }
    return c
}

func r2ClientOptions(cfg config.Configuration) func(*s3.Options) {
    return func(o *s3.Options) {
        if cfg.R2.Endpoint != "" { o.BaseEndpoint = aws.String(cfg.R2.Endpoint) } // https://<account>.r2.cloudflarestorage.com
        o.UsePathStyle = true
    }
}
```

- `r2Configuration` does **not** carry the endpoint; the endpoint is set in `r2ClientOptions`. That config was once handed
  to code that built its own S3 client, and the presigned URLs pointed at AWS. The only ways out: `connectR2()` and
  `connectR2PresignClient()`.
- The same `aws.Config` (region `auto`) must never be used for SES: every send fails with symptoms that look like "an IAM
  problem" ([01-backend-on-aws.md](01-backend-on-aws.md) §4.7).
- R2 rejects a PUT whose type or size differs from the signed `ContentType`/`ContentLength` with 403, and a GET whose
  signature covers `x-amz-checksum-mode` (which an `<img>` never sends) with `SignatureDoesNotMatch`/403. The incident:
  KYC document images broken for two months, until the presigned GET signed the host only.

### 4.3 R2 locally and in e2e

- E2E: the in-memory stand-in (`scripts/e2e/fakes3`) as `R2_ENDPOINT` + `ASSET_PUBLIC_BASE_URL`.
- When real SigV4 signatures need checking: `versity/versitygw` in Docker (bind `127.0.0.1`; CreateBucket needs
  `LocationConstraint auto`).
- Production R2 credentials locally only for objects created by that test itself; never change/delete objects belonging
  to real entities (the files in the production bucket change too).

---

## 5. Credentials & tools

| For | Credentials | Note |
|---|---|---|
| Terraform DNS | Cloudflare API token with scope **Zone → DNS → Edit**, limited to the zone | env `CLOUDFLARE_API_TOKEN` (locally from the keychain, in CI from a GitHub Secret); not a Terraform variable |
| wrangler (Worker, Pages) | `wrangler login` (OAuth) or an API token in CI | Do not run wrangler with cwd = home: `~/.wrangler` (the old config path) hides the login |
| Backend → R2 | R2 access key per bucket/app | SSM; do not use a full-account token |
| Pages Functions | secrets in encrypted Pages env vars | Not in `VITE_*` |

Deploying a Worker or Pages is an outward-facing (production) action: do it only when asked to deploy, and verify
afterwards (§2.1, §3).
