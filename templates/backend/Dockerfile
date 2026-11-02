# Template — replace <org>, <app>, <module>, <port>.
# One image for API and worker; ECS picks the mode through `command` (["main"] / ["worker"]).
FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git ca-certificates

# Private Go modules (internal libraries) are pulled with the token CI passes in (secret GOPRIVATE_TOKEN).
ARG TOKEN
ENV TOKEN=$TOKEN GOPRIVATE=github.com/<org>/*
RUN git config --global url."https://${TOKEN}:x-oauth-basic@github.com/".insteadOf "https://github.com/"

WORKDIR /app
COPY . .
RUN go mod download

# Commit and build time (deploy.yml passes github.sha and epoch seconds). They become buildinfo.Revision —
# the generation of the redifu cache indexes/records — and buildinfo.Time — which build is newer when two builds
# share Redis during a rolling deploy. A build without both runs as "dev" and logs a WARN.
ARG GIT_SHA=""
ARG BUILD_TIME=""

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags "-X <module>/app/buildinfo.Revision=${GIT_SHA} -X <module>/app/buildinfo.Time=${BUILD_TIME}" \
    -o ./<app> ./app/cmd

FROM alpine:3.20
# The runtime image has no time zone database: the application embeds it with
# `import _ "time/tzdata"` in the package that calls time.LoadLocation. The CA bundle is already in the alpine base.
WORKDIR /<app>
COPY --from=builder /app/<app> /<app>/<app>

# config.InitConfig() calls godotenv.Load() and fails if .env is missing, so the file must exist —
# but EMPTY: ECS injects the real configuration as env, and godotenv does not override env that is already set.
RUN touch /<app>/.env

EXPOSE <port>
ENTRYPOINT ["/<app>/<app>"]
CMD ["main"]
