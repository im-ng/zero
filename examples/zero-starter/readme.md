# Zero Starter

A minimal, batteries-included starting point: health, metrics, one SQL route,
and one outbound service call. Copy this directory and build on it.

## What's wired

- `GET /` — plain text liveness.
- `GET /json` — JSON response via `ctx.response.json`.
- `GET /sql` — unified SQL probe through `ctx.SQL` (no table needed). Returns a
  hint when no `DB_DIALECT` is configured, so it runs with zero infra.
- `GET /upstream` — a real outbound call through `app.addHttpService` (circuit
  breaker + `SERVICE_UPSTREAM_*` auth attached automatically).
- `GET /.well-known/health` — health (framework-provided).
- `GET /metrics` — metrics (framework-provided metriczServer).

## Run

```bash
zig build starter            # or: zig build run
# override any config via env, e.g.:
DB_DIALECT=postgres DB_HOST=localhost DB_USER=postgres DB_PASSWORD=postgres DB_NAME=postgres \
  SERVICE_UPSTREAM_BASE_URL=https://api.github.com \
  zig build starter
```

## Deploy

- `Dockerfile` — multi-stage build, non-root, Zig 0.17.0.
- `charts/zero` (repo root) — Helm chart; set `image.repository`/`tag` and
  `env` (HTTP_PORT, DB_*, SERVICE_*, …). See `charts/zero/values.yaml`.
- `.github/workflows/ci.yml` — build, `zig build test`, docker build, helm
  template.

See `docs/` (root of the framework repo) for the full configuration reference,
error-handling guide, and upgrade notes.
