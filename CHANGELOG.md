# Changelog

All notable changes are tracked here. The full, linkable detail lives at
[zerofmk.in](https://zerofmk.in). Version follows the framework's `build.zig.zon`.

## [0.5.4] — current main

Requires **Zig 0.17.0+** (hard cut; does not build on 0.16.x). Full detail in
[RELEASE_NOTES_0.5.4.md](./RELEASE_NOTES_0.5.4.md).

- **Zig 0.17 hard cut** — deps wired to 0.17-ready forks (httpz, protobuf,
  opentelemetry, regexp, sqlite, zbench); `std.Build` port (`@Tuple`,
  `@typeInfo` field arrays, `addPassthruArgs`).
- **Breaking** — min Zig 0.17.0; dependency forks changed; example `build.zig`
  must port `b.args` → `addPassthruArgs()`; vault overrides config removed.
- **Security/audit remediation** — auth session UAF, rate-limiter `Retry-After`
  math, safe Basic-auth decode, pub/sub arena leak, ordered teardown + thread
  joins, context cleanup rollback, cronz schedule-parse hardening.
- **OTel stable** — enabled by OTLP endpoint, not a flag.
- **Outbound resilience** — retry 429/5xx honoring `Retry-After`; Kafka TLS on
  by default; Redis `rdz.reconnect()` + health-probe rebuild.
- **Architecture** — additive named SQL/pub-sub, transactional outbox
  (`addOutbox`), fail-fast startup, `healthProbe`.
- **SBOM** for tagged releases; platform hardening + deployment/community docs.

## [0.5.3]

- Data source additions and coding updates (Postgres + SQLite + pub/sub backends).

## [0.5.2]

- Experimental additions; soak + chaos test coverage across 12 services.

## [0.5.0]

- Bump to Zig 0.16 support.

## [0.0.3] — stable-0.15.2 branch

- Last release targeting Zig 0.15.2.
