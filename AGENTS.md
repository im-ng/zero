# AGENTS.md

## Toolchain

- **Zig 0.15.1** (minimum, pinned in `build.zig.zon`)
- Requires `librdkafka-dev` installed (`apt install librdkafka-dev` / `brew install librdkafka`)
- On macOS, build.zig hardcodes `/usr/local/Cellar/librdkafka/2.13.0` paths

## Commands

```bash
zig build test              # run all unit tests (52 tests)
zig build --release=fast   # release build
make clean                  # remove .zig-cache, zig-out, and all example build artifacts
```

## Testing

- Test runner is `src/tests.zig` — imports all test-bearing modules via `comptime { _ = module; }` references
- Inline `test` blocks live in each source file (Zig convention)
- `build.zig` creates a separate test module from the main module, with the same dependency imports; the test root is `src/tests.zig`
- `std.testing.expectError` needs an error union type (`error.Foo!void`), not a bare error set — wrap with `@as(ErrorSet, error.Foo)` or assign to a typed variable first
- `std.posix.setenv`/`unsetenv` don't exist in Zig 0.15.1 — avoid env var mutation in tests; test with existing vars like `PATH` or unset keys
- Zig 0.15.1 uses `.@"enum".fields` not `.Enum.fields` for `@typeInfo` enum field access
- `utils.combine`/`toString`/`toStringFromInt` allocate 256-byte buffers via `bufPrint` and return subslices — these intentionally don't free; use `std.heap.page_allocator` in their tests
- Functions like `process.setValue` and `host.setValue` allocate via `dupe` and don't return owned memory for the caller to free — test with `std.testing.allocator` and accept GPA leak warnings
- `validateBasicAuth`/`validateAPIKeyAuth` allocate internally from the passed allocator and don't free — same leak expectation
- `src/cronz/scheduler.zig` uses `@import("zero")` which must be `@import("../zero.zig")` to avoid module conflict in test builds
- `src/mw/authProvider.zig` had a compile bug: `@typeInfo(AuthMode).Enum.fields.len` doesn't work in Zig 0.15.1 — fixed to use a `switch`-based `str()` method
- `src/zsutil/cpu.zig` original test "cpu" called `info()` without required `*Context` param — removed the broken call; pure-logic tests for `getFirstNumber`, `calculateCpuUsage`, `setValue` were added instead

## Architecture

- **Entry point**: `src/zero.zig` — re-exports all public types and dependencies
- **App**: `src/app.zig` — main application struct (`App.new(allocator)`, `app.run()`)
- **Context**: `src/context.zig` — request context (`Context`), exposes `.SQL`, `.Cache` (Redis), `.GetService()`
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

## Dependencies (build.zig.zon)

All are Zig packages fetched via git: pg, httpz, metriks, dotenv, zul, okredis (aliased as `rediz`), zdt, regexp, mqttz, jwt. Plus `rdkafka` linked as a C system library.

## Config

Loaded from `configs/.env` at startup, with per-environment overrides (e.g. `configs/.dev.env` when `APP_ENV=dev`).

## Examples

13 example apps in `examples/` (zero-basic, zero-auth, zero-cronz, zero-redis, zero-migration, zero-websocket, zero-stream, zero-service-client, zero-kafka-publisher, zero-kafka-subscriber, zero-mqtt-publisher, zero-mqtt-subscriber, zero-todo-htmx).

## Gotchas

- `rdkafka` is linked as a weak system library — builds will fail without `librdkafka-dev`
- The `kafka` build option in `build.zig` is currently commented out; rdkafka is always linked
- Config keys are all commented out in `configs/.env`; features activate only when uncommented
- Auth modes: `Basic`, `APIKey`, `OAuth` — configured via `AUTH_MODE` env var

### Test coverage (52 tests across 12 files)

| File | Tests | What's tested |
|---|---|---|
| `src/constants.zig` | 5 | Path values, port defaults, status strings, header names, regex patterns |
| `src/utils.zig` | 7 | `combine`, `toString`, `toStringFromInt`, `timestampz`, `sqlTimestampz`, `toCString` |
| `src/responder.zig` | 2 | `Do(void)` type, `Do(*Context)` type |
| `src/http/errors.zig` | 3 | `HttpError`, `CronError`, `ZeroError` error set membership |
| `src/config.zig` | 6 | `getAsBool`, `getAsInt`, `getOrDefault`, `getIntByType` with env vars |
| `src/cronz/job.zig` | 3 | `Job.create`, `compare` match/mismatch |
| `src/cronz/cronz.zig` | 5 | `expandOccurance` ranges, `parseSchedule` validation |
| `src/mw/authProvider.zig` | 3 | `AuthMode.str`, `validateAPIKeyAuth` accept/reject |
| `src/zsutil/memory.zig` | 6 | `usage` (Linux), `percentageUsed`, `setValue` parsing |
| `src/zsutil/cpu.zig` | 5 | `getFirstNumber`, `calculateCpuUsage`, `CpuUsage.getTotal`, `setValue` |
| `src/zsutil/process.zig` | 3 | `setValue` parsing for `VmHWM`, `Threads`, non-matching lines |
| `src/zsutil/host.zig` | 3 | `setValue` parsing for quoted/unquoted values, non-matching lines |