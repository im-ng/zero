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
      <td style="padding: 12px; border: 1px solid #ddd;"><a href="https://deepwiki.com/im-ng/zero"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a></td>
      <td style="padding: 12px; border: 1px solid #ddd;"><img src="https://img.shields.io/badge/Coverage-95-green" alt="Coverage"></td>
      <td style="padding: 12px; border: 1px solid #ddd;"><a href="https://github.com/im-ng/zero/workflows/CI/badge.svg"><img src="https://github.com/im-ng/zero/workflows/CI/badge.svg" alt="Build Status"></a></td>
    </tr>
  </table>
</p>
<br/>

# Zero Framework

![mascot](./static/zero-mascot-1.svg)

**One binary. No GC. Build config-driven microservices in Zig.**

**Zero** is a batteries-included web framework for [Zig](https://ziglang.org) that wires REST, SQL, NoSQL, cache, pub/sub, auth, GraphQL, Protobuf, search, metrics and tracing into a single static binary and configured almost entirely through `.env`.

- **Zero boilerplate** — databases, queues, auth and observability plug in with no glue code.
- **One static binary** — ~16–65 MiB RSS, no runtime, ships anywhere (including Kubernetes).
- **Observable by default** — structured JSON logs, Prometheus metrics, distributed tracing and health endpoints from the first request.
- **Fast and small** — tens of thousands of requests/sec at ~50 MiB RSS, no GC pauses, no JIT warm-up.

---

## Quick Start

Drop this in `src/main.zig`, add a `configs/.env`, and you have a JSON API with
structured logs and `/metrics` live:

```zig
const std = @import("std");
const zero = @import("zero");
const utils = zero.utils;

pub const std_options: std.Options = .{ .logFn = zero.logger.custom };

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const app = try zero.App.new(arena.allocator(), init.io, init.environ_map);
    try app.get("/json", jsonResponse);
    try app.run();
}

fn jsonResponse(ctx: *zero.Context) !void {
    try ctx.json(.{ .msg = "hello zero!" });
}
```

```bash
zig fetch --save https://github.com/im-ng/zero/archive/refs/heads/main.zip
mkdir -p configs && printf 'APP_NAME=hello\nHTTP_PORT=8080\n' > configs/.env
zig build run
curl localhost:8080/json   # => {"msg":"hello zero!"}
```

That's the whole app. Everything else - Postgres, Redis, Kafka, auth, metrics, is opt-in through configuration.

Full walkthrough in [Hello Zero](https://zerofmk.in/hello-zero) and [Getting Started](https://zerofmk.in/started).

## Why Zero?

If you want Go's ergonomics without its runtime, or Node's speed without its footprint, Zero gives you a strongly-opinionated Zig framework: explicit memory, a single binary, and the microservice building blocks you'd otherwise wire together by hand.

Start with [Getting Started](https://zerofmk.in/started) or jump straight to the [Examples](https://zerofmk.in/examples).

## Features

| Category              | Status | Details                                                                                                                                                                                                                                                           |
| --------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| REST / CRUD           | ✅     | Standard REST endpoints out of the box; AutoCRUD for struct models                                                                                                                                                                                                |
| Configuration         | ✅     | `.env` with per-environment overrides ([/configuration](https://zerofmk.in/configuration))                                                                                                                                                                        |
| Logging               | ✅     | Structured, UTC/local timestamps ([/logging](https://zerofmk.in/logging))                                                                                                                                                                                         |
| Metrics               | ✅     | App, HTTP, SQL, KV + process/memory stats ([/observability](https://zerofmk.in/observability))                                                                                                                                                                    |
| Tracing               | ✅     | TraceID middleware, request-level tracing ([/x-ray](https://zerofmk.in/x-ray))                                                                                                                                                                                    |
| Auth                  | ✅     | Basic, API Key, OAuth 2.0 ([/authentication](https://zerofmk.in/authentication))                                                                                                                                                                                  |
| CORS / Panic Recovery | ✅     | Configurable CORS, automatic panic recovery                                                                                                                                                                                                                       |
| Databases             | ✅     | PostgreSQL, SQLite, Redis, DuckDB, InfluxDB, Solr, Cassandra ([/sqlite](https://zerofmk.in/sqlite), [/duckdb](https://zerofmk.in/duckdb), [/cassandra](https://zerofmk.in/cassandra), [/influxdb](https://zerofmk.in/influxdb), [/solr](https://zerofmk.in/solr)) |
| Pub/Sub               | ✅     | MQTT, NATS, Kafka (librdkafka), Redis ([/pubsub](https://zerofmk.in/pubsub))                                                                                                                                                                                      |
| Migrations            | ✅     | DB migrations + seed on startup ([/migrations](https://zerofmk.in/migrations))                                                                                                                                                                                    |
| HTTP Client           | ✅     | Register multiple external services with auth + circuit breakers ([/http-service](https://zerofmk.in/http-service))                                                                                                                                               |
| Cron Jobs             | ✅     | `* * * * *` + second-level + range support ([/cronz](https://zerofmk.in/cronz))                                                                                                                                                                                   |
| WebSockets            | ✅     | Built-in WebSocket support ([/websocket](https://zerofmk.in/websocket))                                                                                                                                                                                           |
| Static Files          | ✅     | Serve static assets + Swagger UI ([/swagger](https://zerofmk.in/swagger))                                                                                                                                                                                         |
| Health Checks         | ✅     | Liveness + status endpoints                                                                                                                                                                                                                                       |
| GraphQL               | ✅     | Schema-less resolvers over HTTP ([/graphql](https://zerofmk.in/graphql))                                                                                                                                                                                          |
| Protobuf              | ✅     | proto3 codegen + bind/decode & encode over HTTP ([/protobuf](https://zerofmk.in/protobuf))                                                                                                                                                                        |

See [feature parity](https://zerofmk.in/parity) for the full roadmap.

## What's New

Recent additions (full detail on [zerofmk.in](https://zerofmk.in)):

- **Zig 0.16 + `std.Io` injection** — `App.new(allocator, io, em)` threads the process I/O reactor through `container`/`Context`; tests are consolidated at each file's end. See [Migrating to 0.16](https://zerofmk.in/migrating-0.16).

- **DuckDB in-process OLAP** — register an embedded SQL engine with `app.addDuckDB(":memory:")`, no external service. See [DuckDB](https://zerofmk.in/duckdb).

- **AutoCRUD for DuckDB** — `app.addRestHandlers` now targets DuckDB too.
  See [Auto CRUD](https://zerofmk.in/auto-crud).

- **CLI Application Mode** — build one-shot jobs or long-running migrations with
  `App.newCmd` + `app.SubCommand`, no HTTP server. See [CLI Mode](https://zerofmk.in/cli).

- **Kubernetes deployment** — sample image build + manifests.
  See [Kubernetes](https://zerofmk.in/kubernetes) and [Container](https://zerofmk.in/container).

- **New data sources** — Cassandra, InfluxDB and Solr join the supported backends.
  See [/cassandra](https://zerofmk.in/cassandra), [/influxdb](https://zerofmk.in/influxdb),
  [/solr](https://zerofmk.in/solr).

- **Bootstrap arena** — Pre-allocated memory for framework bootstrap (bounded RSS). See [Architecture](https://zerofmk.in/architecture).

- **Outbound rate limiting & REST handlers** — per-service rate limits and struct-model REST handlers for external services. See [Rate Limiter](https://zerofmk.in/rate-limiter) and [REST Handler](https://zerofmk.in/rest-handler).
- **Resilience** — circuit breakers, request timeouts/bulkheads, and pub/sub reconnect + dead-letter. See [Resilience](https://zerofmk.in/resilience).

- **Observability** — distributed tracing and structured metrics/tracing wired in from the first request. See [Observability](https://zerofmk.in/observability).

- **Benchmarks in CI** — reproducible throughput/latency/RSS runs. See [Benchmark](https://zerofmk.in/benchmark).

## Examples

Every feature ships with a runnable example under [`examples/`](examples). Pick one and `zig build run` from its directory.

**Basics**

- [`zero-basic`](examples/zero-basic) — JSON / text routes, DB read, key-value, local file store.
- [`zero-stream`](examples/zero-stream) — live host/cpu/status metrics streamed over WebSocket + cron.
- [`zero-websocket`](examples/zero-websocket) — minimal WebSocket handler.
- [`zero-todo-htmx`](examples/zero-todo-htmx) — HTMX UI backed by AutoCRUD.
- [`zero-cli`](examples/zero-cli) — CLI mode: one-shot jobs / migrations, no HTTP server.
- [`zero-cronz`](examples/zero-cronz) — scheduled cron jobs (`* * * * * *`).

**Data & Stores**

- [`zero-sqlite`](examples/zero-sqlite) — SQLite CRUD.
- [`zero-duckdb`](examples/zero-duckdb) — in-process DuckDB OLAP + CRUD.
- [`zero-nosql`](examples/zero-nosql) — Cassandra / NoSQL key-value CRUD.
- [`zero-redis`](examples/zero-redis) — Redis caching.
- [`zero-timeseries`](examples/zero-timeseries) — InfluxDB time-series write/query.
- [`zero-search`](examples/zero-search) — Solr index + search.
- [`zero-filestore`](examples/zero-filestore) — local file upload/download.
- [`zero-s3`](examples/zero-s3) — S3-compatible object store.

**Messaging**

- [`zero-mqtt-publisher`](examples/zero-mqtt-publisher) / [`zero-mqtt-subscriber`](examples/zero-mqtt-subscriber) — MQTT publish/subscribe.
- [`zero-kafka-publisher`](examples/zero-kafka-publisher) / [`zero-kafka-subscriber`](examples/zero-kafka-subscriber) — Kafka publish/subscribe.
- [`zero-nats-publisher`](examples/zero-nats-publisher) / [`zero-nats-subscriber`](examples/zero-nats-subscriber) — NATS publish/subscribe.

**Auth & API**

- [`zero-auth`](examples/zero-auth) — Basic / API-Key / OAuth2 auth handlers.
- [`zero-service-client`](examples/zero-service-client) — outbound HTTP service with auth + circuit breaker.

**GraphQL & Protobuf**

- [`zero-graphql`](examples/zero-graphql) — GraphQL resolvers.
- [`zero-proto`](examples/zero-proto) — Protobuf bind/decode over HTTP + migration.

**Migrations & Deployment**

- [`zero-migration`](examples/zero-migration) — DB migration + seed.
- [`zero-autocrud`](examples/zero-autocrud) — one-line AutoCRUD for a `User` resource.

## Documentation

The full, versioned documentation lives at **[zerofmk.in](https://zerofmk.in)** (Zig 0.16 is the live locale; 0.15.2 is frozen under `/0.15.2/`). You can also ask the repo anything via [DeepWiki](https://deepwiki.com/im-ng/zero). Per-feature deep dives:

- Concepts: [Architecture](https://zerofmk.in/architecture), [Context](https://zerofmk.in/context), [Interface](https://zerofmk.in/interface), [Configuration](https://zerofmk.in/configuration)
- Data: [SQLite](https://zerofmk.in/sqlite), [DuckDB](https://zerofmk.in/duckdb), [Cassandra](https://zerofmk.in/cassandra), [InfluxDB](https://zerofmk.in/influxdb), [Solr](https://zerofmk.in/solr), [KV Store](https://zerofmk.in/kv-store), [File Store](https://zerofmk.in/file-store), [Migrations](https://zerofmk.in/migrations)
- Networking: [HTTP Service](https://zerofmk.in/http-service), [Pub/Sub](https://zerofmk.in/pubsub), [Kafka](https://zerofmk.in/kafka-publisher), [NATS](https://zerofmk.in/nats-publisher), [Rate Limiter](https://zerofmk.in/rate-limiter), [REST Handler](https://zerofmk.in/rest-handler)
- App concerns: [Auth](https://zerofmk.in/authentication), [Resilience](https://zerofmk.in/resilience), [Observability](https://zerofmk.in/observability), [x-ray](https://zerofmk.in/x-ray), [Caching](https://zerofmk.in/caching), [Logging](https://zerofmk.in/logging), [CLI](https://zerofmk.in/cli), [Cron](https://zerofmk.in/cronz), [GraphQL](https://zerofmk.in/graphql), [Protobuf](https://zerofmk.in/protobuf), [WebSocket](https://zerofmk.in/websocket), [Swagger](https://zerofmk.in/swagger), [Testing](https://zerofmk.in/testing), [Benchmark](https://zerofmk.in/benchmark)

## Configuration

Zero is configured through `configs/.env` with per-environment overrides
(`configs/.dev.env`, etc.). A minimal file:

```bash
APP_NAME=my-app
HTTP_PORT=8080
# PostgreSQL
DB_DIALECT=postgres
DB_HOST=localhost
DB_USER=user1
DB_PASSWORD=password1
DB_NAME=mydb
DB_PORT=5432
# Auth
AUTH_MODE=Basic
```

The complete list of keys (Redis, DuckDB, InfluxDB, Solr, Cassandra, Kafka, MQTT, TLS, metrics, logging, rate limiting, RBAC, …) is in [Configuration](https://zerofmk.in/configuration).

## Resilience

Resilience is configured, not coded. Request timeouts/bulkheads, datasource circuit breakers, pub/sub auto-reconnect with dead-letter, and structured logging are all on by default or via env. For outbound services you can also set limits explicitly:

```zig
var svc_opts: zero.client.ServiceOptions = .{};
svc_opts.circuitBreaker = .{ .failure_threshold = 5, .cooldown_ms = 30_000 };
try app.addHttpService("auth-service", app.config.get("SERVICE_URL"), svc_opts);
```

See [Resilience](https://zerofmk.in/resilience) for timeouts, bulkheads and DLQ behavior.

## Metrics & Observability

Prometheus metrics are exposed at `/metrics` and a health endpoint at `/.well-known/health` (liveness/status). Distributed tracing via TraceID is attached to every request.

```bash
curl localhost:8080/metrics   # http_requests_total, app_sql_response, ...
curl localhost:8080/.well-known/health
```

See [Observability](https://zerofmk.in/observability)

## Data & Stores

Attach a datastore with one call; `ctx.SQL`, `ctx.KV`, `ctx.FileStore` light up automatically.

```zig
// In-process OLAP SQL — no external service required.
try app.addDuckDB(":memory:");
// or a relational backend:
// try app.addSQL(...);  try app.addSQLite(...);  try app.addNoSQL(...);

fn listUsers(ctx: *zero.Context) !void {
    const users = try ctx.SQL.queryRows(ctx, User, "SELECT id, name FROM users", .{});
    try ctx.json(.{ .data = users });
}
```

SQL, NoSQL, cache, pub/sub and file stores:

[/sqlite](https://zerofmk.in/sqlite),
[/duckdb](https://zerofmk.in/duckdb),
[/cassandra](https://zerofmk.in/cassandra),
[/influxdb](https://zerofmk.in/influxdb),
[/solr](https://zerofmk.in/solr),
[/kv-store](https://zerofmk.in/kv-store),
[/file-store](https://zerofmk.in/file-store).

## Auto CRUD

One line wires list / get / create / update / delete for a struct model:

```zig
const User = struct { id: i64, name: []const u8, email: []const u8 };
try app.addRestHandlers(User, .{ .resource = "users" });
// GET/POST/PUT/DELETE /users, /users/:id
```

See [Auto CRUD](https://zerofmk.in/auto-crud).

## Auth

Inbound auth is config-driven (`AUTH_MODE = Basic | APIKey | OAuth`). Handlers read the verified claims from the context:

```zig
try app.get("/basic", basicResponse);

fn basicResponse(ctx: *zero.Context) !void {
    const claims = try ctx.getUsername();
    try ctx.json(claims.?);
}
```

See [Authentication](https://zerofmk.in/authentication).

## Pub/Sub & Messaging

Subscribe to MQTT, NATS or Kafka; the same handler shape works for all:

```zig
try app.addKafkaSubscription("topic", onMessage);
// MQTT: try app.addSubscription("topic", onMessage);
// NATS:  try app.addPubSubSubscription("topic", onMessage);

fn onMessage(ctx: *zero.Context) !void {
    // ctx.message holds the payload
}
```

See [Pub/Sub](https://zerofmk.in/pubsub), [Kafka](https://zerofmk.in/kafka-subscriber), [NATS](https://zerofmk.in/nats-subscriber).

## GraphQL

Schema-less resolvers over HTTP (`POST`/`GET`). Struct fields map to types; function fields are invoked as resolvers:

```zig
try app.addGraphQL(query_root, mutation_root);
```

See [GraphQL](https://zerofmk.in/graphql).

## Protobuf

Generate structs from `.proto` and bind/decode over HTTP:

```zig
const msg = try ctx.bindProto(MyProtoMsg);  // POST body -> struct
try ctx.protobuf(msg);                      // struct -> response bytes
```

See [Protobuf](https://zerofmk.in/protobuf).

## CLI Application Mode

Build one-shot commands or long-running migrations without an HTTP server:

```zig
pub fn main(init: std.process.Init) !void {
    const app = try zero.App.newCmd(allocator, init.io, init.environ_map);
    try app.SubCommand("migrate", runMigration, .{ .description = "run migrations" });
    try app.runCmd(init.minimal.args);
}
```

See [CLI Mode](https://zerofmk.in/cli).

## Testing

Handlers are plain functions over `*Context`, so they're trivial to unit test. The framework's own suite runs 130+ tests with coverage; the harness is documented in [Testing](https://zerofmk.in/testing):

```zig
test "health responds ok" {
    const ctx = try Context.initCli(allocator, container);
    try ctx.json(.{ .ok = true });
}
```

## Benchmark

The bundled benchmark harness drives a concurrency ramp and reports throughput, latency percentiles and per-level RSS. CI runs it for regression. Reproduce in [Benchmark](https://zerofmk.in/benchmark).

## Container Deployment

Build a single static binary and deploy anywhere. Sample image + manifests in
[Kubernetes](https://zerofmk.in/kubernetes) and [Container](https://zerofmk.in/container):

```dockerfile
FROM alpine:latest
COPY zig-out/bin/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
```

## Zig Version Compatibility

| Branch            | Version               |
| ----------------- | --------------------- |
| **main**          | 0.16.0 (experimental) |
| **stable-0.15.2** | 0.15.2                |

For stable work prefer the `stable-0.15.2` branch; `main` tracks the 0.16 experimental baseline (including the `std.Io` injection described above). See [Migrating to 0.16](https://zerofmk.in/migrating-0.16).

## Project Structure

```
src/                  framework source (App, Context, container, datasource, pubsub, …)
examples/             26 runnable example apps
configs/.env          per-environment configuration
static/               embedded swagger UI + framework assets
build.zig             build wiring (test / integration / validation / bench)
```

## Known Gotchas

- **Kafka** requires the system `librdkafka` dev package to be installed and
  linked weakly.

  `apt install librdkafka-dev`
  `brew install librdkafka`

- **DuckDB** needs `libduckdb.so`/`duckdb.h` on the library path (see
  [DuckDB](https://zerofmk.in/duckdb)).

- The `kafka` build option is commented out; rdkafka is always linked.

- Auth modes: `Basic`, `APIKey`, `OAuth`.

## Attributions

[Attribution](https://zerofmk.in/attribution).

## License

Apache — see [LICENSE](LICENSE).
