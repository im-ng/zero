<img src="./static/zero-framework-backdrop.png">
<br/>
<p align="center">
    <table>
    <tr style="background-color: #f8f8f8; text-align: center;">
        <th style="padding: 12px; border: 1px solid #ddd;">Documentation</th>
        <th style="padding: 12px; border: 1px solid #ddd;">DeepWiki</th>
        <th style="padding: 12px; border: 1px solid #ddd;">Coverage</th>
        <th style="padding: 12px; border: 1px solid #ddd;">Build Status</th>
    </tr>
    <tr style="text-align: center;">
        <td style="padding: 12px; border: 1px solid #ddd;"><a href="https://zerofmk.in">zerofmk.in</a></td>
        <td style="padding: 12px; border: 1px solid #ddd;"><a href="https://deepwiki.com/badge.svg"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a></td>
        <td style="padding: 12px; border: 1px solid #ddd;"><img src="https://img.shields.io/badge/Coverage-95-green" alt="Coverage"></td>
        <td style="padding: 12px; border: 1px solid #ddd;"><a href="https://github.com/im-ng/zero/workflows/CI/badge.svg"><img src="https://github.com/im-ng/zero/workflows/CI/badge.svg" alt="Build Status"></a></td>
    </tr>
    </table>
</p>
<br/>

**Zero** is a strongly opinionated web framework written in Zig, built on top of http.zig that aims for zero allocations and created to make development easier while keeping performance and observability in mind.

**Zero** framework is completely configurable, you may isolate and attach best-in-class built-in solutions as you see fit using the 12 Factor App methodology.

**Zero** framework has useful features like drop-in support for numerous `databases`, `queuing systems`, and external services, as well as `REST`, `authentication`, `logging`, `metrics`, `observability`, and `scheduling`.

### Zero mascot

<p>
<img src="./static/zero-mascot-1.webp" alt="zero mascot" width="128">
</p>

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Examples](#examples)
- [Testing](#testing)
- [Benchmark](#benchmark)
- [Zig Version Compatibility](#zig-version-compatibility)
- [Known Gotchas](#known-gotchas)
- [Attributions](#attributions)
- [License](#license)

## Features

| Category        | Status | Details                                    |
| --------------- | ------ | ------------------------------------------ |
| REST / CRUD     | ✅     | Build standard REST endpoints out-of-box   |
| Configuration   | ✅     | `.env` with per-environment overrides      |
| Logging         | ✅     | Structured, UTC timestamps                 |
| Metrics         | ✅     | App, HTTP, SQL, KV + process/memory stats  |
| Tracing         | ✅     | TraceID middleware, request-level tracing  |
| Auth Middleware | ✅     | Basic, API Key, OAuth 2.0                  |
| CORS            | ✅     | Configurable CORS middleware               |
| Panic Recovery  | ✅     | Automatic panic recovery                   |
| Databases       | ✅     | PostgreSQL, SQLite, Redis                  |
| Pub/Sub         | ✅     | MQTT, Kafka (via librdkafka)               |
| Migrations      | ✅     | DB migrations + seed on startup            |
| HTTP Client     | ✅     | Register multiple external services        |
| Cron Jobs       | ✅     | `* * * * *` + second-level + range support |
| WebSockets      | ✅     | Built-in WebSocket support                 |
| Static Files    | ✅     | Serve static assets + Swagger UI           |
| Health Checks   | ✅     | Liveness + status endpoints                |

See [feature_parity.md](./feature_parity.md) for the full roadmap and upcoming features.

## Requirements

- **Zig 0.15.1** (tested and production baseline)
- **librdkafka** — required for Kafka support:
  ```bash
  sudo apt install librdkafka-dev   # Linux
  brew install librdkafka           # macOS
  ```

## Installation

Add zero to your project:

```bash
zig fetch --save https://github.com/im-ng/zero/archive/refs/heads/main.zip
```

## Quick Start

### 1. Initialize your project

```bash
mkdir zero-web-app && cd zero-web-app
zig init
zig fetch --save https://github.com/im-ng/zero/archive/refs/heads/main.zip
```

### 2. Configure `build.zig`

```zig
const zero = b.dependency("zero", .{});

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

exe.root_module.addImport("zero", zero.module("zero"));
b.installArtifact(exe);
```

### 3. Create config directory

```bash
mkdir configs
touch configs/.env
```

### 4. Write your app

```zig
const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const app = try App.new(allocator);
    try app.get("/json", jsonResponse);
    try app.run();
}

pub fn jsonResponse(ctx: *Context) !void {
    try ctx.json(.{ .msg = "hello from zero!" });
}
```

### 5. Run

```bash
zig build run
```

```
 INFO [03:23:39] Loaded config from file: ./configs/.env
 INFO [03:23:39] Starting server on port: 8080
```

See [full documentation](https://zerofmk.in/) for detailed guides on authentication, databases, cron jobs, websockets, and more.

## Project Structure

| Directory         | Purpose                                  |
| ----------------- | ---------------------------------------- |
| `src/datasource/` | PostgreSQL (`SQL`), Redis (`Cache`)      |
| `src/pubsub/`     | MQTT and Kafka publishers/subscribers    |
| `src/cronz/`      | Cron scheduler and job execution         |
| `src/migration/`  | Database migrations and seeding          |
| `src/mw/`         | Middleware: auth, tracing, websocket     |
| `src/service/`    | HTTP client for external services        |
| `src/http/`       | Error types and HTTP utilities           |
| `src/zsutil/`     | System utils: memory, CPU, process, host |
| `src/static/`     | Embedded Swagger UI assets               |

Key entry points:

- `src/zero.zig` — re-exports all public types
- `src/app.zig` — main `App` struct (`App.new()`, `app.run()`)
- `src/context.zig` — request context with `.SQL`, `.Cache`, `.GetService()`

## Configuration

Zero loads config from `configs/.env` at startup, with per-environment overrides (e.g. `configs/.dev.env` when `APP_ENV=dev`).

```bash
# Application
APP_NAME=myapp
APP_VERSION=1.0.0
APP_ENV=dev

# Logging
LOG_LEVEL=debug

# PostgreSQL
# DB_HOST=localhost
# DB_USER=user1
# DB_PASSWORD=password1
# DB_NAME=mydb
# DB_PORT=5432
# DB_DIALECT=postgres

# Redis
# REDIS_HOST=127.0.0.1
# REDIS_PORT=6379
# REDIS_USER=redis
# REDIS_PASSWORD=password
# REDIS_DB=0
# REDIS_TLS_ENABLED=false

# Kafka
# KAFKA_BROKER=localhost:9092

# MQTT
# MQTT_HOST=localhost
# MQTT_PORT=1883

# Authentication
# AUTH_MODE=Basic
```

All keys are commented out by default; features activate only when uncommented. See [config.md](./config.md) for the full list.

## Examples

14 example applications are available in the `examples/` directory:

| Example                 | Description                            |
| ----------------------- | -------------------------------------- |
| `zero-basic`            | Minimal HTTP server                    |
| `zero-auth`             | Authentication (Basic, API Key, OAuth) |
| `zero-cronz`            | Cron job scheduling                    |
| `zero-kafka-publisher`  | Kafka message publishing               |
| `zero-kafka-subscriber` | Kafka message consumption              |
| `zero-mqtt-publisher`   | MQTT message publishing                |
| `zero-mqtt-subscriber`  | MQTT message consumption               |
| `zero-redis`            | Redis cache operations                 |
| `zero-sqlite`           | SQLite database usage                  |
| `zero-migration`        | Database migrations                    |
| `zero-service-client`   | External HTTP service client           |
| `zero-stream`           | Streaming responses                    |
| `zero-todo-htmx`        | HTMX-powered CRUD app                  |
| `zero-websocket`        | WebSocket connections                  |

Each example has its own `build.zig` and `build.zig.zon`.

## Testing

```bash
zig build test              # run all unit tests (52 tests)
zig build --release=fast    # release build
make clean                  # remove build artifacts
```

## Benchmark

| Configuration                              | Requests/sec |
| ------------------------------------------ | ------------ |
| Metrics + logging + tracing + info logging | ~16,500      |
| Metrics + logging + tracing                | ~29,800      |
| Metrics + logging (no tracing)             | ~31,000      |
| No metrics                                 | ~31,200      |

Baseline (`none` log level): **~83,000 req/s** over 100s with 100 concurrent connections.

```bash
❯ go-wrk -c 100 -d 100 http://localhost:8080/json
Running 100s test @ http://localhost:8080/json
  100 goroutine(s) running concurrently
8344879 requests in 1m39.643117619s, 1.39GB read
Requests/sec:		83747.67
Transfer/sec:		14.30MB
Overall Requests/sec:	83430.16
Overall Transfer/sec:	14.24MB
Fastest Request:	84µs
Avg Req Time:		1.193ms
Slowest Request:	19.669ms
Number of Errors:	0
10%:			124µs
50%:			150µs
75%:			164µs
99%:			175µs
99.9%:			176µs
99.9999%:		176µs
99.99999%:		176µs
stddev:			743µs
```

## Zig Version Compatibility

| Version | Compiles | Tests | Runtime | Notes                    |
| ------- | -------- | ----- | ------- | ------------------------ |
| 0.15.1  | ✅       | 52/52 | ✅      | Production baseline      |
| 0.15.2  | ✅       | 52/52 | ✅      | Production               |
| 0.16.0  | ❌       | N/A   | N/A     | Build system API changed |

## Known Gotchas

- **`rdkafka`** is linked as a weak system library — builds fail without `librdkafka-dev`
- **Always `rm -rf .zig-cache zig-out zig-pkg/`** before switching Zig versions
- `src/cronz/scheduler.zig` and `src/mw/authProvider.zig` use `@import("../zero.zig")` (relative path), not `@import("zero")`

## Attributions

See [attribution.md](./attribution.md) for details.

## License

[Apache License](./LICENSE)
