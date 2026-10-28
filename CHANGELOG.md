# Changelog

All notable changes are tracked here. The full, linkable detail lives at
[zerofmk.in](https://zerofmk.in). Version follows the framework's `build.zig.zon`.

## [0.5.4] — current main

- **Zig 0.16 + `std.Io` injection** — `App.new(allocator, io, em)` routes the
  process I/O reactor through `container`/`Context`; tests now live at the end
  of each file. See [Migrating to 0.16](https://zerofmk.in/migrating-0.16).
- **DuckDB in-process OLAP** — register an embedded SQL engine with
  `app.addDuckDB(":memory:")`, no external service.
- **AutoCRUD for DuckDB** — `app.addRestHandlers` now targets DuckDB too.
- **CLI Application Mode** — build one-shot jobs or long-running migrations with
  `App.newCmd` + `app.SubCommand`, no HTTP server.
- **Kubernetes deployment** — sample image build + manifests.
- **New data sources** — Cassandra, InfluxDB and Solr join the supported backends.
- **Bootstrap arena** — pre-allocated memory for framework bootstrap (bounded RSS).
- **Outbound rate limiting & REST handlers** — per-service rate limits and
  struct-model REST handlers for external services.
- **Resilience** — circuit breakers, request timeouts and bulkheads, and pub/sub
  reconnect with dead-letter.
- **Observability** — distributed tracing and structured metrics wired in from
  the first request.
- **Benchmarks in CI** — reproducible throughput/latency/RSS runs.

## [0.5.3]

- Data source additions and coding updates (Postgres + SQLite + pub/sub backends).

## [0.5.2]

- Experimental additions; soak + chaos test coverage across 12 services.

## [0.5.0]

- Bump to Zig 0.16 support.

## [0.0.3] — stable-0.15.2 branch

- Last release targeting Zig 0.15.2.
