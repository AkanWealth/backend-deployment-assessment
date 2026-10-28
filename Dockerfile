# syntax=docker/dockerfile:1
#
# Multi-stage build for the MuchToDo Go backend.
#
# Build context is the root of this repository. The application source is
# expected at ./app (a clone of the much-to-do repo, branch feature/backend-only):
#
#   git clone -b feature/backend-only https://github.com/Innocent9712/much-to-do.git app
#   docker build -t muchtodo-backend:latest .

ARG GO_VERSION=1.25
ARG APP_DIR=app/Server/MuchToDo

# ---------- Stage 1: build ----------
FROM golang:${GO_VERSION}-alpine AS builder
ARG APP_DIR

WORKDIR /src

# Download dependencies first so this layer is cached between code changes.
COPY ${APP_DIR}/go.mod ${APP_DIR}/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Copy only the source the binary needs.
COPY ${APP_DIR}/cmd ./cmd
COPY ${APP_DIR}/internal ./internal
COPY ${APP_DIR}/docs ./docs

# Static binary, stripped of debug info.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/much-to-do ./cmd/api

# ---------- Stage 2: runtime ----------
FROM alpine:3.20 AS runtime

# ca-certificates for TLS, tzdata for correct timestamps.
# busybox wget (already in alpine) is used by the HEALTHCHECK.
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app app

WORKDIR /app

COPY --from=builder --chown=app:app /out/much-to-do /app/much-to-do

# The app loads config with viper, which only maps env vars onto keys it
# already knows about. This template lists every key (no secrets) so that
# values passed as container environment variables are picked up.
COPY --chown=app:app <<EOF /app/.env
PORT=8080
MONGO_URI=
DB_NAME=much_todo_db
JWT_SECRET_KEY=
JWT_EXPIRATION_HOURS=72
ENABLE_CACHE=false
REDIS_ADDR=
REDIS_PASSWORD=
LOG_LEVEL=INFO
LOG_FORMAT=json
EOF

USER app:app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/app/much-to-do"]
