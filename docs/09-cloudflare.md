# 09 — Cloudflare: frontend, edge, object storage, DNS

**Decision:** everything the browser sees and all user files live on **Cloudflare**; the backend lives on AWS
([08-aws-infrastructure.md](08-aws-infrastructure.md)).

| Need | Cloudflare service |
|---|---|
| DNS for all domains, proxy + TLS for the API | DNS + proxy (orange cloud), SSL **Full (strict)** |
| User web app (SPA) | **Cloudflare Pages** (Git integration) |
| Internal/admin dashboard (SPA) | **Cloudflare Pages** (separate project) |
| Small server-side logic owned by the frontend | **Pages Functions** (only on the paths that need it) |
| SEO/Open Graph for bots, alias domains | **Cloudflare Worker** "edge" in front of Pages |
| User files & public assets | **R2** (public bucket behind a CDN custom domain; private bucket through presigned URLs) |

---

## 1. Domain map

Use this pattern for new projects (`<domain>` = the product domain):

| Host | Points to | Managed by |
|---|---|---|
| `<domain>` | edge Worker `<project>-edge-main` (custom domain) → Pages `<project>-fe-main` | Dashboard/wrangler |
| `staging.<domain>` | edge Worker `<project>-edge-staging` → Pages `<project>-fe-staging` | wrangler (`custom_domain = true`) |
| `api.<domain>` | CNAME → ALB, **proxied** | Terraform (`cloudflare` module) |
| `cdn.<domain>` | custom domain of the public R2 bucket | R2 dashboard |
| `internal.<domain>` | Pages `internal-dashboard` (production branch) | Pages dashboard |
| short/alias domains (optional) | zone route of the edge Worker (bots: the page; browsers: 301 to `<domain>`) | wrangler (`routes` in `[env.main]`) |
| email records (SES) | verification, DKIM (not proxied), MAIL FROM, SPF, DMARC | Terraform |

- A hostname can belong to only **one** target (Worker/custom domain) at a time; detach it from the old target before
  attaching it to the new one ("already assigned to another service").
- **SSL/TLS mode Full (strict)** on the zone. The API behind the ALB uses a Cloudflare Origin Certificate and the ALB SG
  only accepts Cloudflare IPs — the API record must be proxied.
- **Backend CORS** must list every frontend origin: production, staging, internal/admin, `http://localhost:5173` (local
  dev & e2e), and alias domains when bots that run JavaScript render pages there. The origin list is pinned by a test in
  the backend ([03-api-design.md](03-api-design.md)).

---

## 2. Frontend on Cloudflare Pages

### 2.1 Deploy pattern

- **Pages Git integration, no GitHub Actions in the FE repo.** A push to the production branch (e.g. `main` for the web app,
  `master` for the internal dashboard) = a production deploy within ±1–3 minutes. Other branches get a
  `*.pages.dev` preview.
- Two projects per app when staging hosting is needed: `<project>-fe-main` and `<project>-fe-staging` (branch
  `staging`). There is no mandatory staging backend; the FE staging may point to the production API or be turned off.
- **Definition of "deploy FE":** merge into the production branch, then push to `origin`. No workflow needs to be
  triggered.
- The deploy status shows up as a GitHub check run "Cloudflare Pages: <project>" on the **full SHA** (a short SHA answers
  422). A fast-forward to a SHA that already had a preview build leaves the old check run in place — wait for a **new**
  run (started_at after the push).
- **Live verification:** fetch the production HTML shell → the `/assets/index-*.js` name → match it against the local
  build, or grep the chunk of the changed route.
- Remove old deploy integrations that are no longer used (S3/CloudFront, Vercel) so false red statuses do not hide the
  real status.

### 2.2 Build & configuration

- SPA (e.g. Vue 3 + Vite): `vite build` (production mode reads `.env.production`), output `dist/`.
- **All `VITE_*` values are public** — they ship in the bundle. Never put a secret API key there. Browser keys (Maps,
  OAuth client ID) are restricted in the provider's console (referrer/origin).
- Secrets for Pages Functions are stored as **encrypted environment variables in the Pages dashboard**, not in the repo.
- Absolute URLs for canonical/og:image/sitemap use an origin variable (`VITE_COPY_BASE_URL`) — without it the tags become
  relative and WhatsApp/Facebook link previews cannot load the image.
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

Examples of valid uses:

- **Proxy to a third party that needs a secret** (e.g. an AI API) — the key lives in an encrypted Pages env var, and the
  browser calls `/api/...` on its own origin.
- **Link previews for nested routes** (`/:username/event/:slug`) that the edge Worker does not handle.
- **form_post return URL** of a login provider (Sign in with Apple POSTs to `/log-in`, and the Function hands it over to
  the SPA; GET falls through to the SPA).

Local test: `npx wrangler pages dev dist --port 8788 --compatibility-date=<date>`.

### 2.4 Internal/admin dashboard

A separate SPA repo and a separate Pages project, host `internal.<domain>`, calling the backend's `/admin/...` endpoints
with accounts that have an admin role. Same deploy pattern (push to the production branch = deploy).

---

## 3. Edge Worker in front of Pages

Repo `<project>-edge`: a JavaScript Worker (ES Modules) that behaves like Lambda@Edge in front of Pages.

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

Rules:

- **Browsers always get the SPA exactly as Pages built it.** Bots (the `isbot` package, not a home-made regex) get the
  **same** Pages HTML with SEO/OG/Twitter tags injected through `HTMLRewriter`.
- A Worker cannot service-bind to Pages: it `fetch`es `PAGES_ORIGIN` (`<project>-fe-main.pages.dev`). There is no loop as
  long as the `PAGES_ORIGIN` hostname differs from the Worker's hostname.
- Data comes from the backend's public endpoints (e.g. `GET /user/username/:username`) with a **2.5 s timeout**.
  Timeout/error/`status_code != 200`/empty data → **never a 500**: serve the Pages HTML as is (shell tags + og-default) and
  **do not cache it**, so the next crawl tries again.
- Only a segment shaped like a username (`^[a-z0-9](?:[a-z0-9.-]{0,28}[a-z0-9])?$`, not clashing with app routes) is
  treated as a profile. Static assets (`/assets/*`, `*.js|css|png|…`, `robots.txt`, `sitemap.xml`) are always passed
  through.
- Metadata: `<title>` = `{name} | {APP_NAME}`, the description cut at a word boundary at ±200 characters with a fallback,
  `og:image` = a 1200×630 card rendered by a backend worker and stored in R2 (fallback `DEFAULT_OG_IMAGE`), canonical
  `{APP_BASE_URL}/{username}`. Square avatar images are not used as the card.
- **Alias domains** (`ALIAS_HOSTS`): bots get the page on the alias host (WhatsApp previews do not always follow
  redirects); everyone else gets a **301 to the same path + query** on `APP_BASE_URL`. Build the target URL by setting
  path/query on a `URL(APP_BASE_URL)` object — **do not** use `new URL(path + search, base)`: a path `//evil.com` or
  `/\evil.com` becomes an open redirect.
- **Two environments, one repo** (`wrangler.toml`): `[env.staging]` and `[env.main]` with different Worker names.
  **`[vars]` is not inherited by environments** — every `[env.*.vars]` block must repeat all variables (a forgotten
  variable shows up as `undefined` at runtime, not as a deploy error).
- **Deploy:** `npx wrangler deploy --env main --tag <sha> --message "<summary>"` (or `npm run deploy:main`). Workers
  Builds (auto-deploy from Git) is set up per Worker in the dashboard and can only be attached to a Worker that already
  exists — make sure the branch → Worker mapping is right; otherwise a push can ship staging variables to production.
  Keep the edge repo's `main` and `staging` branches in sync with what is live.
- **Testing:** `curl -A "Slackbot-LinkExpanding 1.0" "https://<domain>/<user>?cb=$RANDOM"`, then check the header
  `x-edge-rendered: bot`, `og:url`, `og:image`. The Cache API key does not depend on the host (prod & staging can serve
  each other's cached bot HTML for 300 s) → always use a cache-buster. `isbot` treats `curl`, Playwright, and
  HeadlessChrome as bots: for real-user behavior use a browser UA.
- Local test: `wrangler dev` with a `.dev.vars` that points `PAGES_ORIGIN` at a static server for `dist/` (SPA fallback)
  and `API_BASE_URL` at the local backend.

---

## 4. Object storage: Cloudflare R2

### 4.1 Buckets

| Bucket | Contents | How it is read |
|---|---|---|
| Public (assets) | avatars, banners, thumbnails, logos, OG cards, posters | public URL `ASSET_PUBLIC_BASE_URL` = the R2 custom domain (`https://cdn.<domain>`) |
| Private (sensitive documents) | KTP/KYC, selfies, identity documents | **Only** short-lived presigned GETs, created by the backend after an access check |
| Others as needed | archives/exports | private |

- One bucket per confidentiality level; do not mix sensitive files into a public bucket.
- `ASSET_PUBLIC_BASE_URL` **must include `https://`** — a value without the scheme once produced og:image URLs that
  returned 404 on every card.
- R2 credentials (access key pair) live in SSM; SSM is the source of truth, local copies can be stale.

### 4.2 Backend client

R2 speaks the S3 API, so the backend uses `aws-sdk-go-v2/service/s3`:

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

- `r2Configuration` does **not** carry the endpoint; the endpoint is set in `r2ClientOptions`. That is why this config is
  never handed to code that builds its own S3 client (that once produced presigned URLs pointing at AWS). The only ways
  out: `connectR2()` and `connectR2PresignClient()`.

### 4.3 Upload: presigned PUT directly from the client

Files **never** go through the API (small request bodies, short connection timeouts):

1. The client asks for an upload URL: `POST …/presign-<object>` with the extension (from an allowlist) and the size.
2. The backend mints the key `<owner prefix>/<uuidv7>.<ext>` (e.g. `user/<uuid>/avatar/…`, `user/<uuid>/clients/…`) and
   a 1-hour **presigned PUT** that **signs `ContentType` and `ContentLength`** (R2 rejects any other type/size with 403),
   then answers `{presign_url, asset_url (= object key), content_type}`.
3. The client `PUT`s the file directly to R2 with the exact headers, then confirms the key to the owning entity's endpoint
   (`PATCH …`).
4. The backend treats the key from the client as input: it must be under that owner's prefix, with no subfolder and an
   allowed extension; it then stores the **relative key** (not a URL) in Postgres. The client prepends the asset host.

- Extension → Content-Type allowlist (`jpg/jpeg → image/jpeg`, `png`, `webp`), **no SVG** (the key's extension decides how
  the object is served). The client converts to WebP before upload, with a size limit per kind.
- **One presign helper** that always signs type & size (a presign that signs only bucket & key lets any type and size
  through).
- The public bucket needs **CORS** for PUTs from the browser and for reading images into a canvas (PDF/render); a bucket
  that is only displayed in `<img>` does not. A CORS error on PUT = bucket configuration, not client code.
- Uploads that are never confirmed: **(improvement)** a bucket lifecycle rule for a temporary-upload prefix, or a
  pending-upload table (otherwise they are never cleaned up).
- Server-side uploads (files the server fetches itself, e.g. an avatar from Google): download → sniff MIME → map MIME →
  extension → `PutObject` with `ContentType` (+ `ContentLength`).

### 4.3a Naming, caching, deletion

- Derived objects (OG cards, renders) are **content-addressed**: key = hash(design version + input), uploaded with
  `Cache-Control: public, max-age=31536000, immutable`; a new design = bump the version constant → a new key (crawlers
  cache images per URL for weeks).
- **Asset host normalization:** a helper that trims, adds `https://` when there is no `://`, and joins with `/`; better
  still, validate at start that `ASSET_PUBLIC_BASE_URL` is an absolute URL (incident: a value without the scheme made
  clients prepend the host twice → every poster/og:image returned 404).
- **Delete objects after the commit**, best-effort, with a timeout (10 s in a request); a failure is logged and swallowed
  (an orphan object is cheaper than a failed delete on a row that has already committed). **MUST NOT** delete inside the
  transaction before the commit.
- **MUST NOT** ever delete shared keys: default assets (`static/…`), template assets used by many entities, old rows that
  store a full URL, keys still referenced by other rows (count references first).
- Account deletion = list per prefix owned by the account (public + private), then delete; **reject an empty uuid** (the
  prefix would become the folder of every account); compliance documents (KYC) are kept. `ListObjects` must use a
  paginator (max 1,000 keys per response).
- **(improvement)** R2 buckets, the CDN custom domain, and CORS are managed by Terraform (Cloudflare provider), or at least
  by a runbook — never only by hand.
- The R2 client has no HTTP timeout of its own: every call in a request/worker uses `context.WithTimeout`.

### 4.4 Reading private files: presigned GET

```go
presignExpired := func(opts *s3.PresignOptions) {
    opts.Expires = PresignGetTTL
    // By default the SDK requests a response checksum through the x-amz-checksum-mode header, which gets SIGNED,
    // but an <img> never sends it → R2 rejects the request (SignatureDoesNotMatch/403). Sign the host only.
    opts.ClientOptions = append(opts.ClientOptions, func(o *s3.Options) {
        o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
    })
}
input := &s3.GetObjectInput{
    Bucket:                     aws.String(bucket),
    Key:                        aws.String(key),
    ResponseContentType:        aws.String(contentTypeFromKey(key)), // render inline in <img>
    ResponseContentDisposition: aws.String("inline"),
}
```

- A presigned GET is created only **after** the usecase has confirmed the caller is entitled (the owner, or an admin with
  the role).
- Log only the key, **never the signed URL**.

### 4.5 R2 locally and in e2e

- E2E: an in-memory stand-in (`scripts/e2e/fakes3`) as `R2_ENDPOINT` + `ASSET_PUBLIC_BASE_URL`.
- When real SigV4 signatures need checking: `versity/versitygw` in Docker (bind `127.0.0.1`; CreateBucket needs
  `LocationConstraint auto`).
- Use production R2 credentials locally only for objects created by that test itself; do not change/delete objects
  belonging to real entities (the files in the production bucket change too).

---

## 5. Credentials & tools

| For | Credentials | Note |
|---|---|---|
| Terraform DNS | Cloudflare API token with scope **Zone → DNS → Edit**, limited to the zone | env `CLOUDFLARE_API_TOKEN` (locally from the keychain, in CI from a GitHub Secret); not a Terraform variable |
| wrangler (Worker, Pages) | `wrangler login` (OAuth) or an API token in CI | Do not run wrangler with cwd = home: `~/.wrangler` (the old config path) hides the login |
| Backend → R2 | R2 access key per bucket/app | SSM; do not use a full-account token |
| Pages Functions | secrets in encrypted Pages env vars | Not in `VITE_*` |

Deploying a Worker/Pages is an outward-facing (production) action: do it only when asked to deploy, and verify
afterwards (§2.1, §3).
