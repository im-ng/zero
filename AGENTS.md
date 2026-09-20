# AGENTS.md

## Communication style

When presenting changes, summaries, or any explanation to the user, follow `writing-style-guide.md`.
- Simplify the language, not the technical idea.
- Use short, active, spoken-style sentences.
- Show the concrete case before the general rule.
- No marketing, hype, filler, or unnecessary summaries.

## Toolchain

- **Zig 0.16.0** minimum, pinned in `build.zig.zon`
- Requires `librdkafka-dev` (`apt install librdkafka-dev` / `brew install librdkafka`)
- On macOS, `build.zig` hardcodes `/usr/local/Cellar/librdkafka/2.13.0` include/lib paths
- **Always `rm -rf .zig-cache zig-out zig-pkg/` before switching Zig versions** — stale cache causes build failures and runtime corruption
- This environment builds and tests with **Zig 0.16.0** (`/usr/local/zig-x86_64-linux-0.16.0/zig`); the deps vendored in `zig-pkg/` compile under it.

## Commands

```bash
zig build test              # unit tests (52; 7 known leaks, assertions pass)
zig build test-integration  # real SQLite :memory: + Postgres integration tests (21)
zig build test-validation   # Context memory-release + timestampz invalid-free (3)
zig build -Dcoverage test   # kcov coverage report -> zig-out/kcov/
zig build bench             # build the HTTP load/benchmark harness
./zig-out/bin/bench         # run the harness (see BENCHMARK.md)
zig build --release=fast    # release build
make clean                  # remove .zig-cache, zig-out, and all example build artifacts
```

## Testing

- Test runner: `src/tests.zig` — imports all test-bearing modules via `comptime { _ = module; }` references
- Inline `test` blocks live in each source file (Zig convention)
- `build.zig` creates a separate test module from the main one; test root is `src/tests.zig`
- **Tests pass (52) but leak memory (7 leaks)** — `std.testing.allocator` detects leaks and the build exits with failure. This is a known issue, not a logic bug.
- `std.testing.expectError` needs an error union type (`error.Foo!void`), not a bare error set — wrap with `@as(ErrorSet, error.Foo)` or assign to a typed variable first
- `std.posix.setenv`/`unsetenv` don't exist in Zig 0.15.2 — test with existing vars like `PATH` or unset keys
- Zig 0.15.2 uses `.@"enum".fields` not `.Enum.fields` for `@typeInfo` enum field access
- `utils.combine`/`toString`/`toStringFromInt` allocate 256-byte buffers via `bufPrint` and return subslices — intentionally don't free; use `std.heap.page_allocator` in their tests
- `process.setValue`, `host.setValue`, `validateBasicAuth`, `validateAPIKeyAuth` allocate via `dupe`/allocator and don't return owned memory — test with `std.testing.allocator` and accept leak warnings
- `utils.timestampz`/`sqlTimestampz`/`DTtimestampz` return **caller-owned** buffers from `std.fmt.allocPrint` — the caller must `allocator.free` them. A prior `bufPrint` version returned a stack-subslice that caused an invalid free; fixed and covered by `test-validation`.

### Test layers

- `zig build test` — unit tests (52; 7 known leaks, assertions pass)
- `zig build test-integration` — real `SQLite :memory:` + Postgres, 21 tests (`src/tests_integration.zig`)
- `zig build test-validation` — Context request/cron/pubsub release + `timestampz` invalid-free fix, 3 tests (`src/tests_validation.zig`, `src/validation/memory_test.zig`)
- `zig build -Dcoverage test` — kcov over `src/` → `zig-out/kcov/` (HTML); measured **87.91%**

### HTTP load / benchmark harness

- `zig build bench` builds `./zig-out/bin/bench`; it starts the real `zero.App` and drives a concurrency ramp, reporting throughput, latency percentiles (fixed-bucket histogram, bounded memory), error count, and per-level RSS (`readRss()` samples `/proc/self/status` VmRSS — 0.0 off-Linux). A `dRss` that keeps climbing (or `peak RSS` that never plateaus) is the leak signal.
- Uses the `zul` HTTP client; each worker times requests with `clock_gettime(CLOCK_MONOTONIC)` (no `std.time.nanoTimestamp` in 0.16.0).
- The framework's liveness endpoint is **`/.well-known/health`** (not `/health`) — hitting `/health` returns 404 by design.
- Full usage, flags, and sample results in `BENCHMARK.md`.
- Flags: `--path=<url>` (default `/.well-known/health`, single scenario), `--suite` / `--target=all` (runs every category below), `--target=<csv>` (subset of `health,http,sql,nosql,timeseries,search,proto,graphql,filestore`, comma-separated), `--host=<host>` `--port=<port>` (benchmark an external zero server instead of booting the embedded app), `--vusers=<N>` (ramp `1,N/4,N/2,N`), `--duration=<s>` per level, `--levels=1,25,100`, `--json` (writes `zig-out/bench/report.json` with per-scenario `{name, peak_rss_mib, drss_kib, leak}`), `--debug-alloc` (runs the server on a `DebugAllocator` and reports leaks at exit — deep but noisy, flags all unfreed startup state too), `--server` (serves the same routes, listens on `HTTP_PORT` default 8080, blocks until Ctrl-C so an external load generator like k6 can drive them).
- The `--suite` (or `--target=all`) drives the `zero-basic` workload at clean paths (registered in `src/bench/main.zig`), grouped by category: `health` (`/.well-known/health`, default JSON + `health-json`/`health-html` content-negotiation variants), `http` (`/`, `/text`, `/json`, `/keys`, `/db`), `sql` (`/duckdb/query` in-memory read path), `proto` (`GET /proto` + `POST /proto` inline `TestMsg` `bindProto`+encode round-trip), `graphql` (`GET /graphql?query=…` + `POST /graphql` pure `Query` resolver), `filestore` (`GET /filestore?key=bench-seed` + `POST /filestore` local `FileStore` save→get→delete; each request uses a unique key so concurrent workers don't race). Gated categories `nosql`/`timeseries`/`search` run only when their backend env var is set.
- The POST `/proto` handler uses an inline `TestMsg{ value: []const u8 }` with `protobuf` field descriptors (`pub usingnamespace protobuf;` + `pub const NAME`/`fd`/encode/decode) — no generated proto. The seed file `./data/bench/bench-seed` is written at startup so `filestore-get` has data.
- The `/.well-known/health` endpoint does content negotiation: `Accept: text/html` → HTML status page (`content_type = .HTML`), otherwise JSON (default, backward compatible). The handler set lives in `src/bench/main.zig` (`indexHandler`, `textHandler`, `jsonHandler`, `keysHandler`, `dbHandler`, `protoGetHandler`, `protoPostHandler`, `filestoreGetHandler`, `filestorePostHandler`, `Query`/resolver).
- CI regression: `.github/workflows/ci.yml` has a `bench_regression` job (Linux `imng/zero-kcov:0.3` container, offline) that runs `./zig-out/bin/bench --suite --json --duration=2 --levels=1,25,100` and diffs `zig-out/bench/report.json` against the committed `bench/baseline.json` (14 scenarios); it fails if any scenario's `peak_rss_mib` grew >15% relative AND >8 MiB absolute, or if `leak:true` appears. On merge to `main` it refreshes `bench/baseline.json` (mirrors the coverage step via `GH_TOKEN`).
- **k6 local baseline**: `bench/k6/baseline.js` is a k6 script that drives the same endpoints (health / health-json / health-html / index / text / json / keys / db / proto-get / graphql-get / filestore-get / proto / graphql / filestore) for a formatted, exportable report (console table + `bench/k6/report.json` + `bench/k6/report.html`). Run the server locally with `./zig-out/bin/bench --server` (listens on `HTTP_PORT`, default 8080, blocks until Ctrl-C), then `k6 run bench/k6/baseline.js` (tune via `BASE_URL`/`VUS`/`DURATION`). The k6 script is the nicer-format local counterpart to the Zig harness; CI still uses the Zig binary for RSS/leak regression.

### Outbound service-client auth + circuit breaker

`app.addHttpService(name, url, opts)` registers a `zero.Client` (`src/service/client.zig`)
that auto-attaches outbound auth to every `get/post/put/delete` and guards the
downstream with a circuit breaker.

- `opts: zero.client.ServiceOptions { auth, circuitBreaker }` — explicit values
  **override** `SERVICE_<NAME>_*` env defaults resolved by `zero.client.fromEnv`
  (service name uppercased, non-alphanumeric → `_`).
- Auth modes mirror the inbound ones: `Basic` → `Authorization: Basic <base64(user:pass)>`,
  `ApiKey` → `x-api-key: <key>`, `OAuth` → `Authorization: Bearer <jwt>`
  (client_credentials grant; token cached + refreshed before expiry via
  `src/service/outbound_auth.zig`).
- Circuit breaker (`src/service/circuit_breaker.zig`): `closed → open → half_open`,
  configurable `failure_threshold` (5), `cooldown_ms` (30000), `half_open_trials` (1);
  `error.CircuitOpen`/`ClientError.CircuitOpen` returned while open.
- Env keys: `SERVICE_<NAME>_AUTH_MODE` (`Basic`/`ApiKey`/`OAuth`),
  `_API_KEY`, `_BASIC_USER`/`_BASIC_PASS`, `_OAUTH_TOKEN_URL`/`_OAUTH_CLIENT_ID`/
  `_OAUTH_CLIENT_SECRET`/`_OAUTH_SCOPE`/`_OAUTH_AUDIENCE`, and
  `_CB_FAILURE_THRESHOLD`/`_CB_COOLDOWN_MS`/`_CB_HALF_OPEN_TRIALS`.

## Architecture

- **Entry point**: `src/zero.zig` — re-exports all public types and dependencies
- **App**: `src/app.zig` — main struct (`App.new(allocator)`, `app.run()`)
- **Context**: `src/context.zig` — request context, exposes `.SQL`, `.Cache` (Redis), `.GetService()`
- **Public import name**: `zero` (consumers do `@import("zero")`)

### Source layout

| Directory | Purpose |
|---|---|
| `src/datasource/` | PostgreSQL (`SQL`), Redis (`rdz`) |
| `src/pubsub/` | MQTT and Kafka pub/sub |
| `src/cronz/` | Cron scheduler and jobs |
| `src/migration/` | DB migrations and seeding |
| `src/mw/` | Middleware: auth, tracing (tracz), websocket |
| `src/service/` | HTTP client for external services |
| `src/http/` | Error types |
| `src/zsutil/` | System utils: memory, cpu, process, host |
| `src/static/` | Embedded swagger UI assets |

## Dependency import names

Three dependency imports have non-obvious module names in `build.zig`:

| Dependency | Import name | Module name |
|---|---|---|
| `okredis` | `rediz` | `okredis` |
| `regexp` | `regexp` | `regex` |
| `jwt` | `jwt` | `zig-jwt` |

## Config

- Loaded from `configs/.env` at startup, with per-environment overrides (e.g. `configs/.dev.env` when `APP_ENV=dev`)
- All config keys are commented out by default; features activate only when uncommented

## Deliberate typos in public API (do not "fix")

These are used consistently across the codebase and must be referenced as-is:

- `AuthProvder` (not `AuthProvider`) — in `zero.zig`, `context.zig`, `container.zig`, `httpServer.zig`, `authz.zig`
- `container.Kakfa` (not `Kafka`) — in `container.zig`, `context.zig`, `app.zig`
- `onStatup` (not `onStartup`) — in `app.zig`

## Examples

13 example apps in `examples/` — each has its own `build.zig.zon` and `build.zig`.

## Gotchas

- `rdkafka` is linked as a weak system library — builds fail without `librdkafka-dev`
- The `kafka` build option in `build.zig` is commented out; rdkafka is always linked
- Auth modes: `Basic`, `APIKey`, `OAuth` — configured via `AUTH_MODE` env var
- `src/cronz/scheduler.zig` and `src/mw/authProvider.zig` use `@import("../zero.zig")` (relative path), not `@import("zero")` — the module name form conflicts in test builds
- `zul.http.Request.header(name, value)` returns an error union — always call it as `try req.header(...)` (the outbound client in `src/service/client.zig` does this)

## Zig version compatibility

| Version | Compiles | Tests | Runtime | Notes |
|---|---|---|---|---|
| 0.15.1 | Yes | 52/52 (7 leaks) | Full | Production baseline |
| 0.15.2 | Yes | 52/52 (7 leaks) | **Broken** | No log output, no HTTP server — `std.fs.File.stdout()` I/O change in logger.zig breaks httpz |
| 0.16.0 | Yes | 52+21+3 | Yes | Works in this env with vendored deps; benchmark HTTP server binds and serves |

- See `ZIG_LEARNINGS.md` for the 0.16.0 migration plan and upgrade notes
- **0.15.2 runtime issue**: `src/logger.zig` uses `std.fs.File.stdout().writer(&stdout_buffer)` pattern which silently fails under 0.15.2 — stdout fd becomes a socket, HTTP server never binds
- **0.16.0 now works here**: the 6 dependency `build.zig` files were updated for the `Module`-based link API and the deps are vendored in `zig-pkg/`, so `zig build {test,test-integration,test-validation,bench}` all pass under 0.16.0.