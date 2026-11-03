# 09 — Frontend, edge, object storage, DNS

Everything the browser sees and every user file: what each part must do and the rules that keep it fast and safe. Which
providers host the frontend, run the edge, store the files, and serve DNS is the project's decision; the requirements
below hold for any of them. One concrete implementation is the
[case study](../case-studies/aws-supabase-cloudflare/03-cloudflare.md).

| Need | What it takes |
|---|---|
| DNS for all domains, proxy + TLS for the API | DNS at a provider that can proxy the API (or a CDN in front of it), TLS verified end to end |
| User web app (SPA) | static hosting with Git deploys and branch previews |
| Internal/admin dashboard (SPA) | a separate static site |
| Small server-side logic owned by the frontend | functions on the static host, **only on the paths that need them** |
| SEO/Open Graph for bots, alias domains | an **edge function** in front of the static site |
| User files & public assets | **S3-compatible object storage**: a public bucket behind a CDN custom domain; a private bucket read through presigned URLs |

Markers: **MUST / MUST NOT / SHOULD**. **(improvement)** = a lesson from production incidents that is not common practice yet; required for new projects.

---

## 1. Domain map

Use this pattern for new projects (`<domain>` = the product domain):

| Host | Points to |
|---|---|
| `<domain>` | the edge function (production) → the static site (production) |
| `staging.<domain>` | the edge function (staging) → the static site (staging), when staging hosting is needed |
| `api.<domain>` | the backend's load balancer, **proxied** through the edge ([08-infrastructure.md](08-infrastructure.md) §4.3) |
| `cdn.<domain>` | the custom domain of the public bucket |
| `internal.<domain>` | the internal/admin dashboard |
| short/alias domains (optional) | the edge function (bots: the page; browsers: 301 to `<domain>`) |
| email records | verification, DKIM (not proxied), MAIL FROM, SPF, DMARC — from the infrastructure code |

- Write down, per host, **what manages it** (infrastructure code, the provider's CLI, its dashboard) in the project's
  runbook, so nobody has to rediscover it.
- A hostname belongs to **one** target at a time; detach it from the old target before attaching it to the new one.
- **TLS is verified end to end** (browser → edge and edge → origin, with a certificate the edge checks). The API's origin
  only accepts the edge's IP ranges, so the API record must be proxied.
- **Backend CORS** must list every frontend origin: production, staging, internal/admin, `http://localhost:5173` (local
  dev & e2e), and alias domains when bots that run JavaScript render pages there. The origin list is pinned by a test in
  the backend ([03-api-design.md](03-api-design.md)).

---

## 2. Frontend hosting

### 2.1 Deploy pattern

- **The static host's Git integration, no deploy workflow in the FE repo.** A push to the production branch (e.g. `main`
  for the web app, `master` for the internal dashboard) = a production deploy within minutes. Other branches get a
  preview URL.
- Two sites per app when staging hosting is needed (production and `staging` branch). There is no mandatory staging
  backend; the FE staging may point to the production API or be turned off.
- **Definition of "deploy FE":** merge into the production branch, then push to `origin`. No workflow needs to be
  triggered.
- Read the deploy status where the host reports it (usually a commit check on the **full** SHA). A fast-forward to a SHA
  that already had a preview build can leave the old status in place — wait for a **new** run that started after the push.
- **Live verification:** fetch the production HTML shell → the `/assets/index-*.js` name → match it against the local
  build, or grep the chunk of the changed route.
- Remove old deploy integrations that are no longer used, so false red statuses do not hide the real status.

### 2.2 Build & configuration

- SPA (e.g. Vue 3 + Vite): `vite build` (production mode reads `.env.production`), output `dist/`.
- **All `VITE_*` values are public** — they ship in the bundle. Never put a secret API key there. Browser keys (Maps,
  OAuth client ID) are restricted in the provider's console (referrer/origin).
- Secrets for the host's functions are stored as **encrypted environment variables on the host**, not in the repo.
- Absolute URLs for canonical/og:image/sitemap use an origin variable (`VITE_COPY_BASE_URL`) — without it the tags become
  relative and WhatsApp/Facebook link previews cannot load the image.
- SPA fallback is handled by the host; dynamic routes that need different HTML for bots are handled by the edge function
  or a host function.

### 2.3 Functions — only on the paths that need them

Functions run only on the paths listed in the host's route manifest; everything else is static assets/SPA fallback without
a function invocation (faster, no invocation cost). Valid uses:

- **Proxy to a third party that needs a secret** (e.g. an AI API) — the key lives in an encrypted host env var, and the
  browser calls `/api/...` on its own origin.
- **Link previews for nested routes** (`/:username/event/:slug`) that the edge function does not handle.
- **form_post return URL** of a login provider (Sign in with Apple POSTs to `/log-in`, and the function hands it over to
  the SPA; GET falls through to the SPA).

### 2.4 Internal/admin dashboard

A separate SPA repo and a separate site, host `internal.<domain>`, calling the backend's `/admin/...` endpoints with
accounts that have an admin role. Same deploy pattern (push to the production branch = deploy).

---

## 3. Edge function in front of the static site

Repo `<project>-edge`: a small function at the edge, in front of the static site.

```
Internet → edge function (router → isbot?)
             │ browser / static assets        │ bot + profile page (/:username, /@:username)
             ▼                                 ▼
        static site (SPA as is)             edge cache (300 s) ── miss ──► in parallel:
                                                                         fetch the site's HTML,
                                                                         fetch the public backend API
                                                                       → build metadata
                                                                       → an HTML rewriter injects into <head>
                                                                       → cache + return HTML
```

Rules:

- **Browsers always get the SPA exactly as the host built it.** Bots (the `isbot` package, not a home-made regex) get the
  **same** HTML with SEO/OG/Twitter tags injected by an HTML rewriter (streaming, not string concatenation).
- The function `fetch`es the static site through its own origin hostname; there is no loop as long as that hostname
  differs from the function's.
- Data comes from the backend's public endpoints (e.g. `GET /user/username/:username`) with a **2.5 s timeout**.
  Timeout/error/`status_code != 200`/empty data → **never a 500**: serve the site's HTML as is (shell tags + og-default) and
  **do not cache it**, so the next crawl tries again.
- Only a segment shaped like a username (`^[a-z0-9](?:[a-z0-9.-]{0,28}[a-z0-9])?$`, not clashing with app routes) is
  treated as a profile. Static assets (`/assets/*`, `*.js|css|png|…`, `robots.txt`, `sitemap.xml`) are always passed
  through.
- Metadata: `<title>` = `{name} | {APP_NAME}`, the description cut at a word boundary at ±200 characters with a fallback,
  `og:image` = a 1200×630 card rendered by a backend worker and stored in object storage (fallback `DEFAULT_OG_IMAGE`),
  canonical `{APP_BASE_URL}/{username}`. Square avatar images are not used as the card.
- **Alias domains** (`ALIAS_HOSTS`): bots get the page on the alias host (WhatsApp previews do not always follow
  redirects); everyone else gets a **301 to the same path + query** on `APP_BASE_URL`. Build the target URL by setting
  path/query on a `URL(APP_BASE_URL)` object — **do not** use `new URL(path + search, base)`: a path `//evil.com` or
  `/\evil.com` becomes an open redirect.
- **Two environments, one repo** (staging and production, different function names). When the tool's environments do
  not inherit variables, every environment repeats all of them (a forgotten variable shows up as `undefined` at runtime,
  not as a deploy error).
- **Deploy** by hand from the branch that matches production, tagged with the SHA and a message. If an auto-deploy from
  Git is attached, make sure the branch → environment mapping is right; otherwise a push can ship staging variables to
  production. Keep the edge repo's `main` and `staging` branches in sync with what is live.
- **Testing:** `curl -A "Slackbot-LinkExpanding 1.0" "https://<domain>/<user>?cb=$RANDOM"`, then check a response
  header that marks bot rendering (e.g. `x-edge-rendered: bot`), `og:url`, `og:image`. If the edge cache key does not
  include the host, production and staging can serve each other's cached bot HTML → always use a cache-buster. `isbot`
  treats `curl`, Playwright, and HeadlessChrome as bots: for real-user behavior use a browser UA.
- Local test: the provider's local runner with the site origin pointed at a static server for `dist/` (SPA fallback)
  and `API_BASE_URL` at the local backend.

---

## 4. Object storage (S3 API)

### 4.1 Buckets

| Bucket | Contents | How it is read |
|---|---|---|
| Public (assets) | avatars, banners, thumbnails, logos, OG cards, posters | public URL `ASSET_PUBLIC_BASE_URL` = the bucket's custom domain (`https://cdn.<domain>`) |
| Private (sensitive documents) | KTP/KYC, selfies, identity documents | **Only** short-lived presigned GETs, created by the backend after an access check |
| Others as needed | archives/exports | private |

- One bucket per confidentiality level; do not mix sensitive files into a public bucket.
- `ASSET_PUBLIC_BASE_URL` **must include `https://`** — a value without the scheme once produced og:image URLs that
  returned 404 on every card.
- Storage credentials (an access key pair per bucket/app, never a full-account token) live in the secret store; the
  secret store is the source of truth, local copies can be stale.

### 4.2 Backend client

Any store that speaks the S3 API works with `aws-sdk-go-v2/service/s3` (a client library, not a choice of provider):

```go
// app/cmd/connection.go
func storageConfiguration(cfg config.Configuration) aws.Config {
    optFns := func(o *awsConfig.LoadOptions) error {
        o.Region = cfg.Storage.Region
        o.Credentials = credentials.StaticCredentialsProvider{Value: aws.Credentials{
            AccessKeyID: cfg.Storage.AccessKeyID, SecretAccessKey: cfg.Storage.SecretAccessKey}}
        // Newer SDK versions add flexible checksum trailers by default; S3-compatible stores that do not
        // implement them reject the request. Only when required → presigned PUTs stay valid.
        o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
        return nil
    }
    c, err := awsConfig.LoadDefaultConfig(context.TODO(), optFns)
    if err != nil { log.Panic(err) }
    return c
}

func storageClientOptions(cfg config.Configuration) func(*s3.Options) {
    return func(o *s3.Options) {
        if cfg.Storage.Endpoint != "" { o.BaseEndpoint = aws.String(cfg.Storage.Endpoint) }
        o.UsePathStyle = true
    }
}
```

- The configuration does **not** carry the endpoint; the endpoint is set in the client options. That is why this config
  is never handed to code that builds its own S3 client (that once produced presigned URLs pointing at the SDK's default
  endpoint instead of the store). The only ways out: `connectStorage()` and `connectStoragePresignClient()`.
- The storage configuration is for storage only: a client for another provider service (e.g. email) builds its own
  configuration — a config made for the store (its region, its keys) fails every call with symptoms that look like a
  permissions problem.

### 4.3 Upload: presigned PUT directly from the client

Files **never** go through the API (small request bodies, short connection timeouts):

1. The client asks for an upload URL: `POST …/presign-<object>` with the extension (from an allowlist) and the size.
2. The backend mints the key `<owner prefix>/<uuidv7>.<ext>` (e.g. `user/<uuid>/avatar/…`, `user/<uuid>/clients/…`) and
   a 1-hour **presigned PUT** that **signs `ContentType` and `ContentLength`** (the store then rejects any other
   type/size with 403), then answers `{presign_url, asset_url (= object key), content_type}`.
3. The client `PUT`s the file directly to the store with the exact headers, then confirms the key to the owning entity's
   endpoint (`PATCH …`).
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
- **(improvement)** buckets, the CDN custom domain, and CORS are managed by the infrastructure code, or at least by a
  runbook — never only by hand.
- The storage client has no HTTP timeout of its own: every call in a request/worker uses `context.WithTimeout`.

### 4.4 Reading private files: presigned GET

```go
presignExpired := func(opts *s3.PresignOptions) {
    opts.Expires = PresignGetTTL
    // By default the SDK requests a response checksum through the x-amz-checksum-mode header, which gets SIGNED,
    // but an <img> never sends it → the store rejects the request (SignatureDoesNotMatch/403). Sign the host only.
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

### 4.5 Object storage locally and in e2e

- E2E: an in-memory stand-in (`scripts/e2e/fakes3`) as `STORAGE_ENDPOINT` + `ASSET_PUBLIC_BASE_URL`.
- When real SigV4 signatures need checking: an S3-compatible server in Docker that verifies them (e.g.
  `versity/versitygw`), bound to `127.0.0.1`.
- Use production storage credentials locally only for objects created by that test itself; do not change/delete objects
  belonging to real entities (the files in the production bucket change too).

---

## 5. Credentials & tools

| For | Credentials | Note |
|---|---|---|
| DNS records from the infrastructure code | a DNS provider token scoped to **DNS edit on one zone** | an env var for the IaC tool (locally from the keychain, in CI from a CI secret); not an IaC variable |
| Edge function & static host deploys | the provider CLI's login (OAuth) or a token in CI | a production action (below) |
| Backend → object storage | an access key per bucket/app | in the secret store; never a full-account token |
| Host functions | secrets in the host's encrypted env vars | not in `VITE_*` |

Deploying the edge function or a static site is an outward-facing (production) action: do it only when asked to deploy,
and verify afterwards (§2.1, §3).
