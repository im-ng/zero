# AGENTS.md

## Toolchain

- **Zig 0.15.2** minimum, pinned in `build.zig.zon`
- Requires `librdkafka-dev` (`apt install librdkafka-dev` / `brew install librdkafka`)
- On macOS, `build.zig` hardcodes `/usr/local/Cellar/librdkafka/2.13.0` include/lib paths
- **Always `rm -rf .zig-cache zig-out zig-pkg/` before switching Zig versions** — stale cache causes build failures and runtime corruption

## Commands

```bash
zig build test              # run all unit tests
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

## Zig version compatibility

| Version | Compiles | Tests | Runtime | Notes |
|---|---|---|---|---|
| 0.15.1 | Yes | 52/52 (7 leaks) | Full | Production baseline |
| 0.15.2 | Yes | 52/52 (7 leaks) | **Broken** | No log output, no HTTP server — `std.fs.File.stdout()` I/O change in logger.zig breaks httpz |
| 0.16.0 | No | N/A | N/A | Build system API changed; dependency build.zig files fail first |

- See `recommendation.md` for full analysis and 0.16.0 migration plan
- **0.15.2 runtime issue**: `src/logger.zig` uses `std.fs.File.stdout().writer(&stdout_buffer)` pattern which silently fails under 0.15.2 — stdout fd becomes a socket, HTTP server never binds
- **0.16.0 compilation blocked** by 6 dependency `build.zig` files using removed `Compile.linkLibC()` / `Compile.linkSystemLibrary()` / `Compile.addLibraryPath()` (moved to `Module` in 0.16.0)