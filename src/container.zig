const std = @import("std");
const root = @import("zero.zig");
const build_options = @import("build_options");
const container = @This();
const Self = @This();

// internal
const pgz = root.pgz;
const constants = root.constants;
const Context = root.Context;
const Metricz = root.metricz;
const rediz = root.rediz;
const rdzClient = root.rediz.Client;
const rdzDatasource = root.rdz;
const zeroClient = root.client;
const MQTT = root.MQTT;
const mqConfig = root.mqConfig;
const natsConfig = root.natsConfig;
const rdkafka = root.rdkafka;
const kafka = root.kafka;
const utils = root.utils;

pub const HealthCheck = struct {
    name: []const u8,
    check: *const fn (*container) anyerror!void,
};

/// One published health-check result. `name` borrows from the registered
/// `HealthCheck` (whose strings live for the whole process), so the snapshot
/// slice itself needs no per-entry allocations.
pub const HealthStatus = struct {
    name: []const u8,
    up: bool,
};

/// Upper bound on health checks whose watchdog thread is still parked on a hung
/// check. A check that never returns keeps exactly one thread for its lifetime;
/// without this cap, every refresh cycle would spawn another one for the same
/// check and thread usage would grow without limit.
const MAX_HEALTH_PROBES: usize = 64;

/// Watchdog state for a single health check running on its own thread. Allocated
/// per probe from `container.allocator`; freed only once `done` flips true, so a
/// detached thread can always finish writing to its box. The check's identity is
/// copied by value because it points into `container.healthChecks`, whose backing
/// array appends can reallocate while this probe runs.
pub const ProbeBox = struct {
    c: *container,
    name: []const u8,
    check: *const fn (*container) anyerror!void,
    up: bool = false,
    /// Release store on completion; readers poll with acquire semantics.
    done: std.atomic.Value(bool) = .init(false),

    fn run(bx: *ProbeBox) void {
        // The check reports its own outcome; any error means DOWN. This is the
        // same semantics as `runHealthCheck`, just off the request path.
        bx.up = if (bx.check(bx.c)) true else |_| false;
        bx.done.store(true, .release);
    }
};

/// Probes SQL connectivity for the health endpoint. For Postgres it acquires and
/// releases a pooled connection (failing the check if the pool is exhausted or
/// the server is unreachable). For in-process engines (SQLite, DuckDB) a
/// successful load already implies health; DuckGres reuses the Postgres pool.
fn sqlHealthCheck(c: *container) anyerror!void {
    if (c.SQL) |sql| {
        const conn = try sql.sql.acquire();
        sql.sql.release(conn);
        return;
    }
    if (c.SQLite) |_| {
        return;
    }
    if (c.DuckDB) |_| {
        return;
    }
    if (c.DuckGres) |dg| {
        const conn = try dg.sql.acquire();
        dg.sql.release(conn);
        return;
    }
    return error.DatasourceUnavailable;
}

/// Probes ClickHouse connectivity for the health endpoint via a trivial
/// `SELECT 1` over HTTP. Fails the check if the server is unreachable.
fn clickhouseHealthCheck(c: *container) anyerror!void {
    if (c.ClickHouse) |ch| {
        _ = try ch.runRaw(c.allocator, "SELECT 1");
        return;
    }
    return error.DatasourceUnavailable;
}

/// Probes Redis connectivity for the health endpoint via a PING round-trip.
fn redisHealthCheck(c: *container) anyerror!void {
    if (c.redis) |*r| {
        // Serialize on the shared Redis socket so a concurrent KV/rate-limiter
        // command can't interleave RESP frames
        if (c.rdz) |rz| {
            rz.mu.lock(utils.io) catch {};
            defer rz.mu.unlock(utils.io);
        }
        const pong = r.sendAlloc([]u8, c.allocator, .{"ping"}) catch {
            // The shared socket may have died in an outage. Rebuild it in place
            // once before declaring Redis unavailable — this heals KV, the rate
            // limiter, and the health probe at the same time (they all borrow the
            // same `rdz` reader/writer interfaces).
            if (c.rdz) |rz| {
                rz.reconnect() catch return error.RedisUnavailable;
                return;
            }
            return error.RedisUnavailable;
        };
        c.allocator.free(pong);
        return;
    }
    return error.RedisUnavailable;
}

/// Runs a single health check and returns `true` only if it succeeds.
///
/// The check is a synchronous `anyerror!void` dispatched on the caller's thread,
/// so this returns the actual dependency status (`true` = UP, `false` = DOWN) and
/// does NOT enforce a timeout. Prefer health-snapshot mode
/// (`startHealthRefresher` / `HEALTH_SNAPSHOT_REFRESH_MS`), which runs checks off
/// the request path; with snapshot mode on, a hung dependency wedges only the
/// refresher while `GET /.well-known/health` keeps serving the last known state.
pub fn runHealthCheck(self: *container, hc: *HealthCheck) bool {
    return if (hc.check(self)) true else |_| false;
}

/// Appends a check under the snapshot guard so the background refresher can copy
/// the check list each cycle without racing an append that reallocates the
/// backing array (dangling slice / torn `HealthCheck` values).
pub fn addHealthCheckEntry(self: *container, name: []const u8, check: *const fn (*container) anyerror!void) !void {
    // Lock failure would mean a corrupted mutex (see publishHealthSnapshot);
    // registration proceeds rather than losing the check.
    self.health_snapshot_mu.lock(self.io) catch {};
    defer self.health_snapshot_mu.unlock(self.io);
    try self.healthChecks.append(.{ .name = name, .check = check });
}

/// Frees the previous snapshot (if any) and publishes `results`, which must be
/// allocated from `self.allocator` by the caller and which this call takes
/// ownership of (the next publish frees it). Timestamped on the monotonic clock
/// for probe freshness checks.
fn publishHealthSnapshot(self: *container, results: []HealthStatus, now: std.Io.Timestamp) void {
    // `std.Io.Mutex.lock` cannot fail in normal operation (only a corrupted
    // mutex reports an error); proceeding unlocked keeps the health endpoint
    // answering, mirroring the scheduler's best-effort locking in cronz.
    self.health_snapshot_mu.lock(self.io) catch {};
    defer self.health_snapshot_mu.unlock(self.io);
    if (self.health_snapshot) |old| {
        self.allocator.free(old);
    }
    self.health_snapshot = results;
    self.health_snapshot_at = now;
}

/// Releases watchdog boxes whose threads have finished (they can only finish
/// after their `ProbeBox` writes are complete and `done` was store-released, so
/// freeing here is safe). Slots live in `health_probe_slots`, guarded by the
/// snapshot mutex; callers hold it. `pub` for `container_test.zig` cleanup.
pub fn reapDoneProbes(self: *container) void {
    for (&self.health_probe_slots) |*slot| {
        const bx = slot.* orelse continue;
        if (!bx.done.load(.acquire)) continue;
        slot.* = null;
        self.allocator.destroy(bx);
    }
}

/// Synchronously runs every registered check on the current thread and publishes
/// the results for the next probe. Used by the probe handler as a fallback
/// (before the first refresher cycle, when the refresher is disabled, or when
/// its snapshot has gone stale) so a cold probe still reports real state.
pub fn runAndPublishHealthChecks(self: *container) void {
    // Copy the check list while holding the guard, then release it before the
    // checks run: `publishHealthSnapshot` re-locks the same mutex, and the check
    // functions themselves take backend locks that must not nest inside it.
    self.health_snapshot_mu.lock(self.io) catch return;
    const checks = self.allocator.alloc(HealthCheck, self.healthChecks.items.len) catch {
        self.health_snapshot_mu.unlock(self.io);
        return;
    };
    @memcpy(checks, self.healthChecks.items);
    self.health_snapshot_mu.unlock(self.io);
    defer self.allocator.free(checks);

    // Owned by the snapshot once `publishHealthSnapshot` takes it; the next
    // publish frees this slice.
    const results = self.allocator.alloc(HealthStatus, checks.len) catch return;
    for (checks, 0..) |*hc, i| {
        results[i] = .{ .name = hc.name, .up = self.runHealthCheck(hc) };
    }
    self.publishHealthSnapshot(results, utils.nowMonotonic());
}

/// A single snapshot refresh on the background refresher thread: reap finished
/// probes, spawn one detached watchdog per check (capped at `MAX_HEALTH_PROBES`,
/// skipping checks that still have a thread running), wait up to `deadline_ms`
/// for the checks it started, and publish every decided result. A check that
/// never returns keeps its one thread and stays `DOWN` in every snapshot until
/// it completes; the refresh loop itself always advances.
pub fn refreshHealthSnapshot(self: *container, deadline_ms: u64) void {
    self.health_snapshot_mu.lock(self.io) catch return;
    self.reapDoneProbes();

    var spawned: usize = 0;
    for (self.healthChecks.items) |*hc| {
        // A check with a thread still parked on a hung dependency keeps its last
        // published state; never spawn a second thread for it.
        var in_flight = false;
        for (self.health_probe_slots) |slot| {
            if (slot != null and std.mem.eql(u8, slot.?.name, hc.name)) {
                in_flight = true;
                break;
            }
        }
        if (in_flight) continue;
        if (spawned >= MAX_HEALTH_PROBES) break; // slot cap; snapshot stays authoritative

        const bx = self.allocator.create(ProbeBox) catch continue;
        bx.* = .{ .c = self, .name = hc.name, .check = hc.check };

        // Claim an empty slot under the same guard that protects the pollers.
        var placed = false;
        for (&self.health_probe_slots) |*slot| {
            if (slot.* == null) {
                slot.* = bx;
                placed = true;
                break;
            }
        }
        if (!placed) {
            self.allocator.destroy(bx);
            continue;
        }

        const thread = std.Thread.spawn(.{}, ProbeBox.run, .{bx}) catch {
            // Spawn failure is transient (thread/table pressure); give the slot
            // back so the next cycle can retry instead of pinning a fake "in
            // flight" entry until process exit.
            for (&self.health_probe_slots) |*slot| {
                if (slot.* == bx) {
                    slot.* = null;
                }
            }
            self.allocator.destroy(bx);
            if (spawned == 0) {
                self.log.err("health refresher could not spawn a watchdog thread");
            }
            continue;
        };
        spawned += 1;
        thread.detach();
    }
    self.health_snapshot_mu.unlock(self.io);
    if (spawned == 0) {
        // Nothing new to wait for; republish the current state to refresh the
        // freshness stamp cheaply.
        self.republishCurrentState();
        return;
    }

    // Poll until every probe we spawned completes or the deadline passes. The
    // deadline bounds snapshot staleness; probes that miss it stay DOWN.
    const deadline = utils.nowMonotonic();
    while (utils.ageMs(deadline) < deadline_ms) {
        // Sleep-forever is harmless here: the next poll iteration re-evaluates
        // the deadline, matching the scheduler's sleep-until web (crontz).
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(25), .awake) catch {};
        var remaining = false;
        // Broken-mutex tolerance as above; poll is read-only bookkeeping.
        self.health_snapshot_mu.lock(self.io) catch {};
        for (self.health_probe_slots) |slot| {
            if (slot != null and !slot.?.done.load(.acquire)) {
                remaining = true;
                break;
            }
        }
        self.health_snapshot_mu.unlock(self.io);
        if (!remaining) break;
    }

    // Build the next snapshot under the guard: the probe results and the
    // previous snapshot rows must be read together. Do NOT reap first — the
    // finished boxes are the only home of the `up` values being published.
    self.health_snapshot_mu.lock(self.io) catch return;

    // Publish a result row per registered check: the probe result for finished
    // watchdogs, else the previous snapshot value, else DOWN.
    const results = self.allocator.alloc(HealthStatus, self.healthChecks.items.len) catch {
        self.health_snapshot_mu.unlock(self.io);
        return;
    };
    for (self.healthChecks.items, 0..) |*hc, i| {
        var up = false;
        var found = false;
        for (self.health_probe_slots) |slot| {
            const bx = slot orelse continue;
            if (std.mem.eql(u8, bx.name, hc.name) and bx.done.load(.acquire)) {
                up = bx.up;
                found = true;
                break;
            }
        }
        if (!found) {
            if (self.health_snapshot) |prev| {
                for (prev) |row| {
                    if (std.mem.eql(u8, row.name, hc.name)) {
                        up = row.up;
                        break;
                    }
                }
            }
        }
        results[i] = .{ .name = hc.name, .up = up };
    }
    // Drop the guard before publishing: `publishHealthSnapshot` takes the same
    // mutex, and `std.Io.Mutex` is not recursive (holding it across the call
    // self-deadlocks the refresher on the first cycle that spawns a probe).
    self.health_snapshot_mu.unlock(self.io);
    self.publishHealthSnapshot(results, utils.nowMonotonic());

    // Release the finished watchdog boxes now that their results are published.
    self.health_snapshot_mu.lock(self.io) catch return;
    self.reapDoneProbes();
    self.health_snapshot_mu.unlock(self.io);
}

/// Re-stamps the published snapshot as just refreshed when a cycle observed no
/// new probes (nothing got scheduled): the checks that ran hold their values.
fn republishCurrentState(self: *container) void {
    // Broken-mutex tolerance as in `publishHealthSnapshot`; the re-stamp is
    // bookkeeping, not a decision path.
    self.health_snapshot_mu.lock(self.io) catch return;
    defer self.health_snapshot_mu.unlock(self.io);
    // An empty check list still needs a valid "no components" snapshot so the
    // probe has something fresh to serve.
    if (self.health_snapshot == null) {
        const results = self.allocator.alloc(HealthStatus, 0) catch return;
        self.health_snapshot = results;
    }
    self.health_snapshot_at = utils.nowMonotonic();
}

/// True when snapshot mode is on (`health_refresh_ms > 0`) and the published
/// snapshot is recent enough to serve. Freshness budget: two missed cycles
/// (floored at 2s for very short intervals), so a dead or wedged refresher
/// degrades to inline probing instead of freezing a stale status on the wire.
pub fn healthSnapshotFresh(self: *container, interval_ms: u64) bool {
    if (interval_ms == 0) return false;
    self.health_snapshot_mu.lock(self.io) catch return false;
    defer self.health_snapshot_mu.unlock(self.io);
    if (self.health_snapshot == null) return false;
    const budget = @max(3 * interval_ms, 2_000);
    return utils.ageMs(self.health_snapshot_at) <= budget;
}

/// Runs one refresh cycle immediately, then loops at `health_refresh_ms`.
/// Spawned detached; the OS reaps the thread at process exit.
fn refresherLoop(self: *container) void {
    const interval_ms = @max(self.health_refresh_ms, 1);

    while (!self.health_refresh_stop.load(.acquire)) {
        const deadline_ms = @max(interval_ms * 2, 10_000);
        self.refreshHealthSnapshot(deadline_ms);
        // Sleep in small steps so the stop flag is honored promptly. Sleep
        // failure only means the sleep didn't complete; the loop re-checks the
        // stop flag regardless.
        var slept: u64 = 0;
        while (slept < interval_ms and !self.health_refresh_stop.load(.acquire)) {
            const step: u64 = if (interval_ms - slept < 100) interval_ms - slept else 100;
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(step)), .awake) catch {};
            slept += step;
        }
    }
}

/// Starts the background health refresher. Detached thread; spawn
/// failure logs and leaves the endpoint on inline probing (correct, just not
/// hung-check-proof).
pub fn startHealthRefresher(self: *container) void {
    if (self.health_refresh_ms == 0) return;
    const thread = std.Thread.spawn(.{}, refresherLoop, .{self}) catch {
        self.log.err("health refresher thread failed to start; falling back to inline probing");
        return;
    };
    thread.detach();
}

pub fn stopHealthRefresher(self: *container) void {
    self.health_refresh_stop.store(true, .release);
}

/// A user-registered static-file mount: URL `prefix` → on-disk `dir`.
pub const StaticMount = struct {
    prefix: []const u8,
    dir: []const u8,
};

/// Returns the mount whose `prefix` is a path-prefix of `path` (with a `/`
/// boundary), plus the remaining path to resolve under `dir`. `null` if no
/// mount matches. Pure — safe to unit test without a live request.
pub fn staticResolve(mounts: []const StaticMount, path: []const u8) ?struct { mount: StaticMount, rel: []const u8 } {
    for (mounts) |m| {
        if (path.len >= m.prefix.len and std.mem.startsWith(u8, path, m.prefix)) {
            const after = path[m.prefix.len..];
            if (after.len == 0 or after[0] == '/') {
                return .{ .mount = m, .rel = after };
            }
        }
    }
    return null;
}

appName: []const u8 = undefined,
appVersion: []const u8 = undefined,
/// Set once `App.run()` has finished wiring and the HTTP server is listening.
/// Surfaced by `GET /.well-known/startup` so k8s can use a dedicated startup
/// probe with a longer timeout than the readiness probe.
started: std.atomic.Value(bool) = .init(false),
allocator: std.mem.Allocator,

/// Process-wide I/O reactor (one per process in Zig 0.16's `std.Io`). Injected
/// at `App` creation and reachable from every subsystem that holds a
/// `*container` (datasources, cron, pub/sub, context). The `utils.io` global
/// mirrors this for stateless helpers that have no container in scope.
io: std.Io = undefined,

/// Optional pre-allocated bootstrap arena (Tier A). When null it falls back to
/// `allocator`. Set by `App.new` from `ZERO_FRAMEWORK_MEM_SIZE`; used for
/// framework-internal bootstrap wiring (maps, auth keys, startup log buffers)
/// that is never tied to a request lifecycle.
bootstrap_allocator: ?std.mem.Allocator = null,
/// Resolved bootstrap allocator (`bootstrap_allocator` orelse `allocator`).
bootstrap: std.mem.Allocator = undefined,

log: *root.logger = undefined,
config: *root.config = undefined,
metricz: *root.metricz = undefined,
/// OpenTelemetry provider (inert unless an OTLP exporter endpoint is configured). Set by App.initBase.
otel: *root.otel.Provider = undefined,
/// Transactional-outbox configuration (null until App.addOutbox is called).
outbox_options: ?root.outbox.Options = null,
authProvider: *root.AuthProvider = undefined,

/// optional role-based access control registry, wired into the rbac middleware
rbac: ?*root.rbac.RBAC = null,

redis: ?rediz.Client = null,
rdz: ?*root.rdz = null,
SQL: ?*root.SQL = null,
MySQL: ?*root.MySQL = null,
SQLite: ?*root.SQLite = null,
datasource: root.Datasource = undefined,

// In-process OLAP SQL engine (DuckDB). Linked via libs/libduckdb.so.
DuckDB: ?*root.DuckDB = null,

// Wired (network) DuckDB client. Speaks the Postgres wire protocol to a
// DuckDB PG-wire front-end (e.g. duckgres / PostDuck); no duckdb C library
// linked. Selected via DB_DIALECT=duckgres and exposed on ctx.SQL.
DuckGres: ?*root.DuckGres = null,

// Columnar OLAP SQL engine (ClickHouse) over HTTP. No native driver / C lib.
ClickHouse: ?*root.ClickHouse = null,

// Specialized datasources (Round 1: time-series / search).
Timeseries: ?*root.Timeseries = null,
Search: ?*root.Search = null,

// NoSQL datasource (Round 1: document / wide-column).
NoSQL: ?*root.NoSQL = null,
nosql_backend: ?root.nosqlInterface.Backend = null,

// Graph datasource (Round 3: Dgraph over its HTTP query/mutate API).
Graph: ?*root.Graph = null,
services: ?std.StringHashMap(*zeroClient) = null,
// Outbound websocket clients (App.addWebsocketClient). Tracked so each
// background thread is joined and the client freed on container teardown.
wsClients: ?std.StringHashMap(*root.wsclient.Client) = null,
kvStores: std.StringHashMap(*root.KVStore) = undefined,
defaultKV: ?*root.KVStore = null,
fileStores: std.StringHashMap(*root.FileStore) = undefined,
defaultFileStore: ?*root.FileStore = null,
// Named SQL datasources (registered via App.addSQL) and named pub/sub
// backends (registered via App.addPubSub). The single wired datasource /
// pub/sub backend is also available under the "default" key.
sqlStores: std.StringHashMap(root.Datasource) = undefined,
pubSubBackends: std.StringHashMap(*root.PubSub) = undefined,
mqtt: ?*root.MQTT = null,
Kafka: ?*root.kafka = null,
Nats: ?*root.nats = null,
Redis: ?*root.redisPubSub = null,
Sqs: ?*root.sqs = null,
Gcp: ?*root.gcpPubSub = null,
pubSub: ?*root.PubSub = null,

// user-registered static-file mounts (served by the staticDirectory catch-all)
staticMounts: std.array_list.Managed(StaticMount) = undefined,

// GraphQL resolver roots (set by App.graphql; read by the dispatch handler)
graphql_query: ?*const anyopaque = null,
graphql_mutation: ?*const anyopaque = null,

// user-registered health checks surfaced by GET /.well-known/health
healthChecks: std.array_list.Managed(HealthCheck) = undefined,

// The background refresher (`startHealthRefresher`)
// runs the registered checks off the request path every `health_refresh_ms` and
// publishes the results here, so a hung check wedges only the refresher while the
// probe keeps answering from the last-known state. `0` disables the refresher and
// restores fully synchronous probing.
health_snapshot_mu: std.Io.Mutex = .init,
health_snapshot: ?[]HealthStatus = null,
health_snapshot_at: std.Io.Timestamp = undefined,
health_refresh_ms: u64 = 0,
/// Detached watchdog threads are capped at MAX_HEALTH_PROBES; a slot holds a box
/// while its check thread is still running. Guarded by `health_snapshot_mu`.
health_probe_slots: [MAX_HEALTH_PROBES]?*ProbeBox = @splat(null),
health_refresh_stop: std.atomic.Value(bool) = .init(false),

pub fn create(self: Self) anyerror!*container {
    const c = try self.allocator.create(container);
    errdefer self.allocator.destroy(c);

    c.* = .{
        .allocator = self.allocator,
        .log = self.log,
        .config = self.config,
        .io = self.io,
        .bootstrap = if (self.bootstrap_allocator) |b| b else self.allocator,
    };

    c.appName = c.config.getOrDefault(constants.APP_NAME, "zero");
    c.appVersion = c.config.getOrDefault(constants.APP_VERSION, "dev");

    // refresher and keeps health probing fully synchronous.
    // 0 disables the background
    const refresh_raw = c.config.getOrDefault("HEALTH_SNAPSHOT_REFRESH_MS", "5000");
    c.health_refresh_ms = std.fmt.parseInt(u64, refresh_raw, 10) catch blk: {
        // utils.combine returns a subslice of a fixed 256-byte buffer and is
        // intentionally not freed (one-shot log line at startup).
        const msg = utils.combine(
            c.allocator,
            "invalid HEALTH_SNAPSHOT_REFRESH_MS '{s}', using default 5000",
            .{refresh_raw},
        ) catch break :blk 5000;
        c.log.err(msg);
        break :blk 5000;
    };

    // initialize service client handler maps
    c.services = std.StringHashMap(*zeroClient).init(c.bootstrap);
    c.wsClients = std.StringHashMap(*root.wsclient.Client).init(c.bootstrap);

    // initialize kv stores (backends registered via App.addKVStore / loadRedis)
    c.kvStores = std.StringHashMap(*root.KVStore).init(c.bootstrap);

    // initialize file stores (backends registered via App.addFileStore / loadFileStore)
    c.fileStores = std.StringHashMap(*root.FileStore).init(c.bootstrap);

    // initialize named SQL datasources (registered via App.addSQL) and named
    // pub/sub backends (registered via App.addPubSub)
    c.sqlStores = std.StringHashMap(root.Datasource).init(c.bootstrap);
    c.pubSubBackends = std.StringHashMap(*root.PubSub).init(c.bootstrap);

    // initialize user-registered health checks
    c.healthChecks = std.array_list.Managed(container.HealthCheck).init(c.bootstrap);

    // initialize user-registered static mounts
    c.staticMounts = std.array_list.Managed(container.StaticMount).init(c.bootstrap);

    // Startup is fail-fast: a backend that is configured but fails to connect
    // returns its error, propagated by the `try` calls below, so the process
    // exits non-zero instead of calling std.process.exit mid-startup.
    // initialize metricz
    try c.loadMetricz();

    // initialize db
    try c.loadSQL();
    if (c.SQL != null or c.MySQL != null or c.SQLite != null or c.DuckDB != null or c.ClickHouse != null or c.DuckGres != null) {
        c.sqlStores.put("default", c.datasource) catch {};
    }

    // initialize kv
    try c.loadRedis();

    // initialize file store (local backend auto-registered from FILE_STORE_ROOT)
    try c.loadFileStore();

    // initialize sqlite
    try c.loadSQLite();

    // initialize duckdb (in-process OLAP SQL) when configured
    try c.loadDuckDB();

    // initialize duckgres (wired DuckDB over the Postgres wire protocol) when
    // DB_DIALECT=duckgres is set; shares the DB_* connection configuration.
    // try c.loadDuckGres();

    // initialize clickhouse (columnar OLAP SQL over HTTP) when configured
    try c.loadClickhouse();

    // initialize specialized datasources (time-series / search) when configured
    try c.loadTimeseries();

    try c.loadTimeseriesOpenTSDB();

    try c.loadSearch();

    // initialize nosql datasource (document / wide-column) when configured
    try c.loadNoSQL();

    try c.loadNoSQLArango();

    // initialize graph datasource (Dgraph) when configured
    try c.loadGraph();

    // initilize message queues
    try c.loadPubSub();
    if (c.pubSub != null) {
        c.pubSubBackends.put("default", c.pubSub.?) catch {};
    }

    c.log.info("container is created");

    return c;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;

    // Metric registry: frees every built-in vec (and its duped label strings) plus
    // the custom metric list. The metrics server thread is already stopped/joined
    // by the time `App.run` reaches this point, so no concurrent access is possible.
    self.metricz.deinit(allocator);

    // File stores: both the type-erased wrapper and its backend impl are allocated
    // from the general allocator. The `fileStores` map struct itself lives in the
    // bootstrap arena and is freed by `App.deinit`.
    var fs_it = self.fileStores.iterator();
    while (fs_it.next()) |entry| {
        entry.value_ptr.*.deinit(allocator);
    }

    // KV stores: same ownership model as file stores.
    var kv_it = self.kvStores.iterator();
    while (kv_it.next()) |entry| {
        entry.value_ptr.*.deinit(allocator);
    }

    // Outbound HTTP service clients.
    if (self.services) |*svcs| {
        var svc_it = svcs.iterator();
        while (svc_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
    }

    // Outbound websocket clients: stop (join) each background thread and free the
    // client plus its datasource-wired Context. Runs before config/log teardown
    // because the client threads reference the container while alive.
    if (self.wsClients) |*cls| {
        var cl_it = cls.iterator();
        while (cl_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
    }

    // Pub/sub clients: signal stop, join their background threads, and free the
    // structures (audit #12). The unified PubSub wrapper is heap-allocated in
    // loadPubSub and freed here too. Runs before config/log teardown because the
    // client destroy paths log through `container.log`.
    if (comptime build_options.kafka) {
        if (self.Kafka) |k| {
            k.destroy();
            allocator.destroy(k);
        }
    }
    if (self.mqtt) |m| {
        m.destroy();
        allocator.destroy(m);
    }
    if (self.Nats) |n| {
        n.destroy();
        allocator.destroy(n);
    }
    if (self.Redis) |r| {
        r.destroy();
        allocator.destroy(r);
    }
    if (self.pubSub) |ps| {
        allocator.destroy(ps);
    }
    // SQS / GCP consumer threads must be joined (and their state freed) before the
    // allocator behind them is torn down. They are heap-allocated in loadSqsPubSub /
    // loadGcpPubSub and owned here
    if (self.Sqs) |s| {
        s.deinit();
        self.Sqs = null;
    }
    if (self.Gcp) |g| {
        g.deinit();
        self.Gcp = null;
    }
    self.Kafka = null;
    self.mqtt = null;
    self.Nats = null;
    self.Redis = null;
    self.pubSub = null;

    // Config and logger only wrap borrowed pointers (the env map / io), so freeing
    // the structs is sufficient.
    self.config.deinit();
    self.log.deinit();

    // Shared SQL datasource: closes the pg connection pool, then frees the struct.
    if (self.SQL) |sql| {
        sql.deinit();
        allocator.destroy(sql);
    }

    // MySQL datasource: closes the pooled connections and frees the struct
    // allocated by `loadMySQL` / `MySQL.create`. `MySQL.deinit` frees the struct
    // itself, so no separate `allocator.destroy` is needed here.
    if (self.MySQL) |m| {
        m.deinit();
    }

    // In-process OLAP engine (DuckDB): closes the C database/connection and the
    // struct allocated by `create` / `addDuckDB`.
    if (comptime build_options.duckdb) {
        if (self.DuckDB) |db| {
            db.deinit(allocator);
        }
    }

    // Wired (network) DuckDB client: closes the pgz pool, then frees the struct
    // allocated by `loadDuckGres` / `DuckGres.create`.
    if (self.DuckGres) |db| {
        db.deinit();
        allocator.destroy(db);
    }

    // Columnar OLAP engine (ClickHouse): frees the HTTP client and the struct.
    if (self.ClickHouse) |ch| {
        ch.deinit(allocator);
    }

    // Time-series backend (InfluxDB/Couchbase/mock): frees the client and handle.
    if (self.Timeseries) |ts| {
        ts.deinit(allocator);
    }

    // NoSQL backend (Cassandra/Couchbase/mock): frees the type-erased handle and
    // the backend implementation it wraps (connection + any duped config strings).
    if (self.NoSQL) |n| {
        n.deinit(allocator);
    }

    // Search backend (Solr/mock): frees the type-erased handle and the backend
    // implementation it wraps (HTTP client + duped url/collection strings).
    if (self.Search) |s| {
        s.deinit(allocator);
    }

    // Graph backend (Dgraph/mock): frees the type-erased handle and the backend
    // implementation it wraps (HTTP client + duped url/key strings).
    if (self.Graph) |g| {
        g.deinit(allocator);
    }

    // Redis datasource: closes the connection and frees the wrapper struct.
    if (self.rdz) |rdz| {
        rdz.close();
        allocator.destroy(rdz);
    }

    allocator.destroy(self);
}

fn loadPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const pubsub = self.config.get("PUBSUB_BACKEND");
    if (std.mem.eql(u8, pubsub, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, "KAFKA", pubsub)) {
        try self.loadKafkaPubSub();
    } else if (std.mem.eql(u8, "MQTT", pubsub)) {
        try self.loadMqttPubSub();
    } else if (std.mem.eql(u8, "NATS", pubsub)) {
        try self.loadNatsPubSub();
    } else if (std.mem.eql(u8, "REDIS", pubsub)) {
        try self.loadRedisPubSub();
    } else if (std.mem.eql(u8, "SQS", pubsub)) {
        try self.loadSqsPubSub();
    } else if (std.mem.eql(u8, "GCP", pubsub) or std.mem.eql(u8, "GOOGLE", pubsub)) {
        try self.loadGcpPubSub();
    } else {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        self.log.debug(buffer);
    }
}

fn loadKafkaPubSub(self: *Self) !void {
    if (comptime !build_options.kafka) return;
    var mode: c_uint = rdkafka.RD_KAFKA_PRODUCER;

    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 1024);

    var error_message: [512]u8 = undefined;
    const servers = self.config.get("PUBSUB_BROKER");
    if (std.mem.eql(u8, servers, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as broker(s) is/are not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const consumerID = self.config.get("CONSUMER_ID");
    const batchBytes = self.config.getOrDefault("KAFKA_BATCH_BYTES", "1048576");
    const batchTimeout = self.config.getOrDefault("KAFKA_BATCH_TIMEOUT", "1000");
    const batchSize = self.config.getOrDefault("KAFKA_BATCH_SIZE", "100");

    const saslProtocol = self.config.getOrDefault("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT");
    const saslMechanism = self.config.getOrDefault("KAFKA_SASL_MECHANISM", "PLAIN");
    const saslUsername = self.config.get("KAFKA_SASL_USERNAME");
    const saslPassword = self.config.get("KAFKA_SASL_PASSWORD");

    const kafkaTlsCertFile = self.config.get("KAFKA_TLS_CERT_FILE");
    const kafkaTlsKeyFile = self.config.get("KAFKA_TLS_KEY_FILE");
    const kafkaTlsCACertFile = self.config.get("KAFKA_TLS_CA_CERT_FILE");
    const kafkaTlsSkipVerify = self.config.getOrDefault("KAFKA_TLS_INSECURE_SKIP_VERIFY", "false");

    const config: ?*rdkafka.struct_rd_kafka_conf_s = rdkafka.rd_kafka_conf_new();

    if (self.kafkaConfSet(buffer, config, "bootstrap.servers", servers, &error_message)) {
        return error.KafkaConfigError;
    }

    if (std.mem.eql(u8, consumerID, "") == false) {
        mode = rdkafka.RD_KAFKA_CONSUMER;

        if (self.kafkaConfSet(buffer, config, "group.id", consumerID, &error_message)) {
            return error.KafkaConfigError;
        }
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = self.kafkaConfSet(buffer, config, "batch.num.messages", batchSize, &error_message);
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = self.kafkaConfSet(buffer, config, "request.timeout.ms", batchTimeout, &error_message);
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = self.kafkaConfSet(buffer, config, "batch.size", batchBytes, &error_message);
    }

    if (saslProtocol.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "security.protocol", saslProtocol, &error_message);
    }

    if (saslMechanism.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "sasl.mechanism", saslMechanism, &error_message);
    }

    if (saslUsername.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "sasl.username", saslUsername, &error_message);
    }

    if (saslPassword.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "sasl.password", saslPassword, &error_message);
    }

    if (kafkaTlsKeyFile.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "ssl.key.location", kafkaTlsKeyFile, &error_message);
    }

    if (kafkaTlsCertFile.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "ssl.certificate.location", kafkaTlsCertFile, &error_message);
    }

    if (kafkaTlsCACertFile.len > 0) {
        _ = self.kafkaConfSet(buffer, config, "ssl.ca.location", kafkaTlsCACertFile, &error_message);
    }

    _ = self.kafkaConfSet(buffer, config, "enable.ssl.certificate.verification", kafkaTlsSkipVerify, &error_message);

    self.log.info(try std.fmt.bufPrint(buffer, "connecting to kafka at '{s}'", .{servers}));

    self.Kafka = kafka.create(self, config, null, mode) catch |err| {
        buffer = try self.bootstrap.alloc(u8, 1024);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to kafka at '{s}'", .{servers});
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    self.log.info(try std.fmt.bufPrint(buffer, "connected to kafka at '{s}'", .{servers}));

    switch (mode) {
        rdkafka.RD_KAFKA_PRODUCER => {
            self.log.info("kafka publisher mode enabled");
        },
        rdkafka.RD_KAFKA_CONSUMER => {
            self.log.info("kafka subscriber mode enabled");
        },
        else => {
            //do nothing
        },
    }

    // build the unified PubSub dispatcher
    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Kafka)), .vtable = &root.kafka.vtable };
    self.pubSub = ps;
}

/// Set one rdkafka config option. Returns true if rdkafka rejected it, so the
/// caller can decide whether to abort (fatal) or continue (best-effort). Logs
/// the rdkafka-provided error into `log_buf`.
fn kafkaConfSet(
    self: *Self,
    log_buf: []u8,
    config: ?*rdkafka.struct_rd_kafka_conf_s,
    key: []const u8,
    value: []const u8,
    err_buf: *[512]u8,
) bool {
    if (rdkafka.rd_kafka_conf_set(config, key.ptr, value.ptr, err_buf, err_buf.len) != rdkafka.RD_KAFKA_CONF_OK) {
        _ = std.fmt.bufPrint(log_buf, "connection to kafka failed: error occurred {s}", .{err_buf.*}) catch |err| {
            self.log.any(err);
            return true;
        };

        self.log.err(log_buf);
        return true;
    }
    return false;
}

/// Wire a datasource pointer into the container with an optional circuit breaker.
/// Shared by every `load*` backend so the breaker-conditional isn't duplicated.
fn wireDatasource(self: *Self, ptr: anytype, dialect: anytype) void {
    self.datasource = root.Datasource.init(
        ptr,
        dialect,
        if (self.config.getAsBool("SQL_CIRCUIT_BREAKER_ENABLE"))
            root.circuit_breaker.CircuitBreaker.init(.{})
        else
            null,
        self.metricz,
    );
}

/// Register the shared SQL health probe used by postgres/sqlite/duckdb.
fn registerSqlHealth(self: *Self) !void {
    try self.addHealthCheckEntry("sql", sqlHealthCheck);
}

fn loadMqttPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const pubsub = self.config.get("PUBSUB_BACKEND");
    if (std.mem.eql(u8, pubsub, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, pubsub, "MQTT") == false) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, not valid backend provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const hostname = self.config.get("MQTT_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as mqtt host is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const port = self.config.get("MQTT_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mqtt failed: mqtt port is empty.", .{});
        self.log.err(buffer);
        return;
    }

    // const protocol = self.config.getOrDefault("MQTT_PROTOCOL", "tcp");
    const username = self.config.getOrDefault("MQTT_USER", "");
    const password = self.config.getOrDefault("MQTT_PASSWORD", "");
    const clientID = self.config.getOrDefault("MQTT_CLIENT_ID_SUFFIX", "-none");
    // const keepalive = self.config.getAsBool("MQTT_KEEP_ALIVE");
    const portAsInt = try self.config.getAsInt("MQTT_PORT");
    const qos = try self.config.getAsInt("MQTT_QOS");
    const retain = self.config.getAsBool("MQTT_RETRIEVE_RETAINED");

    const config = &mqConfig{
        .clientID = clientID,
        .hostname = hostname,
        .ip = hostname,
        .username = username,
        .password = password,
        .keepAliveDuaration = 1,
        .qos = qos,
        .retainOnRetrieval = retain,
        .port = portAsInt,
        .connectionTimeout = 10_000,
    };

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connecting to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    self.log.info(buffer);

    self.mqtt = MQTT.create(self, config) catch |err| {
        buffer = try self.bootstrap.alloc(u8, 256);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    if (self.mqtt) |pb| {
        try pb.mqtt.ping(.{});
    }

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    self.log.info(buffer);

    // build the unified PubSub dispatcher
    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.mqtt)), .vtable = &root.MQTT.vtable };
    self.pubSub = ps;
}

fn loadNatsPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const url = self.config.get("PUBSUB_BROKER");
    if (std.mem.eql(u8, url, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as nats broker is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const stream = self.config.get("NATS_STREAM");
    const subjects = self.config.getOrDefault("NATS_SUBJECTS", "");
    const max_wait = try self.config.getAsInt("NATS_MAX_WAIT");
    const max_pull_wait = try self.config.getAsInt("NATS_MAX_PULL_WAIT");
    const consumer = self.config.get("NATS_CONSUMER");
    const creds_file = self.config.get("NATS_CREDS_FILE");

    const config = natsConfig{
        .url = url,
        .stream = stream,
        .subjects = subjects,
        .max_wait_ms = @intCast(max_wait),
        .max_pull_wait_ms = @intCast(max_pull_wait),
        .consumer = consumer,
        .creds_file = creds_file,
    };

    self.Nats = root.nats.create(self, &config) catch |err| {
        buffer = try self.bootstrap.alloc(u8, 256);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to NATS at '{s}'", .{url});
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    // build the unified PubSub dispatcher
    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Nats)), .vtable = &root.nats.vtable };
    self.pubSub = ps;
}

fn loadRedisPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 256);

    const hostname = self.config.get("REDIS_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis pubsub is disabled, as redis host is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const port = self.config.get("REDIS_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis pubsub is disabled, as redis port is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const user = self.config.get("REDIS_USER");
    const password = self.config.get("REDIS_PASSWORD");
    const dbInt = self.config.getAsInt("REDIS_DB") catch 0;
    const portInt = try self.config.getAsInt("REDIS_PORT");

    self.Redis = root.redisPubSub.create(self, hostname, portInt, user, password, @intCast(dbInt)) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not connect to Redis pubsub at '{s}:{d}'", .{ hostname, portInt });
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Redis)), .vtable = &root.redisPubSub.vtable };
    self.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "redis pubsub enabled at '{s}:{d}'", .{ hostname, portInt });
    self.log.info(buffer);
}

fn loadSqsPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 256);

    const queue_url = self.config.get("SQS_QUEUE_URL");
    if (std.mem.eql(u8, queue_url, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "sqs pubsub is disabled, as SQS_QUEUE_URL is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    self.Sqs = root.sqs.create(self) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not initialize SQS pubsub", .{});
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Sqs)), .vtable = &root.sqs.vtable, .native_dlq = true };
    self.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "sqs pubsub enabled at '{s}'", .{queue_url});
    self.log.info(buffer);
}

fn loadGcpPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 256);

    const project = self.config.get("GCP_PROJECT");
    if (std.mem.eql(u8, project, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "gcp pubsub is disabled, as GCP_PROJECT is not provided.", .{});
        self.log.debug(buffer);
        return;
    }
    const subscription = self.config.get("GCP_SUBSCRIPTION");
    if (std.mem.eql(u8, subscription, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "gcp pubsub is disabled, as GCP_SUBSCRIPTION is not provided.", .{});
        self.log.err(buffer);
        return;
    }

    self.Gcp = root.gcpPubSub.create(self) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not initialize GCP pubsub", .{});
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    const ps = try self.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Gcp)), .vtable = &root.gcpPubSub.vtable, .native_dlq = true };
    self.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "gcp pubsub enabled for project '{s}'", .{project});
    self.log.info(buffer);
}

pub fn natsPullWaitMs(self: *Self) u32 {
    return @intCast(self.config.getAsInt("NATS_MAX_PULL_WAIT") catch constants.DEFAULT_NATS_MAX_PULL_WAIT_MS);
}

fn loadMetricz(self: *Self) !void {
    // Resolve the per-metric label-cardinality cap from config (which honors
    // `configs/.env`). Absent => default (initialize applies 4096); `0` => disabled
    // (null); positive => that value. This replaces the old `std.c.environ` read so
    // config-driven limits actually take effect
    const card_present = !std.mem.eql(u8, self.config.get("METRICS_CARDINALITY_LIMIT"), "");
    const card_raw = self.config.getAsInt("METRICS_CARDINALITY_LIMIT") catch 0;
    const cap_override: ?usize = if (!card_present) null else if (card_raw == 0) null else card_raw;

    // initialize metrics
    self.metricz = try Metricz.initialize(self.allocator, .{ .prefix = "", .exclude = null }, cap_override);

    // app metrics
    try self.metricz.info(.{ .app_name = self.appName, .app_version = self.appVersion, .zero_version = "0.0.1" });

    try self.metricz.appThreads(.{ .label = "app_threads" }, 0);

    try self.metricz.appMemoryUsage(.{ .label = "app_memory_usage" }, 0);

    try self.metricz.appMemoryTotal(.{ .label = "app_memory_total" }, 0);

    // http metrics
    try self.metricz.response(.{ .path = "/", .method = "GET", .status = 200 }, 0);

    // redis metrics
    // todo

    // pub/sub metrics
    // todo

    // SQL metrics
    try self.metricz.sqlResponse(.{ .hostname = "", .database = "", .query = "", .operation = "select" }, 0);
}

fn loadRedis(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const hostname = self.config.get("REDIS_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis is disabled, as redis host is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const port = self.config.get("REDIS_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database port is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const user = self.config.get("REDIS_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: user name is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const password = self.config.get("REDIS_PASSWORD");
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database password is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const dbInt = try self.config.getAsInt("REDIS_DB");
    const portInt = try self.config.getAsInt("REDIS_PORT");

    const addr = std.Io.net.IpAddress.parse(hostname, portInt) catch
        try std.Io.net.IpAddress.resolve(utils.io, hostname, portInt);

    // Startup resilience: transient Redis unavailability during orchestrated
    // bring-up (sidecar not ready, DNS, brief outage) must not hard-fail the
    // whole process. Retry with exponential backoff before giving up. (Replaces
    // the old `std.process.exit(1)` on connect failure.)
    const max_retries: usize = blk: {
        const v = self.config.getAsInt("REDIS_CONNECT_RETRIES") catch 0;
        break :blk if (v == 0) 5 else @as(usize, v);
    };
    var backoff_ms: u64 = blk: {
        const v = self.config.getAsInt("REDIS_CONNECT_BACKOFF_MS") catch 0;
        break :blk if (v == 0) 500 else @as(u64, v);
    };

    var attempt: usize = 0;
    while (attempt <= max_retries) : (attempt += 1) {
        const connection = addr.connect(utils.io, .{ .mode = .stream }) catch |err| {
            if (attempt < max_retries) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "redis connect attempt {d} failed ({any}); retrying in {d}ms", .{ attempt + 1, err, backoff_ms }) catch "redis connect attempt failed; retrying";
                self.log.warn(msg);
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            buffer = try std.fmt.bufPrint(buffer, "redis connection failed after {d} retries: {any}", .{ max_retries, err });
            self.log.err(buffer);
            return error.RedisConnectFailed;
        };

        self.rdz = try rdzDatasource.create(self.allocator);
        // Keep the connection and its reader/writer inside the heap-allocated `rdz` for
        // the app's lifetime. `rdzClient.init` borrows `&rdz.reader.interface` /
        // `&rdz.writer.interface`; stack-local copies would be freed before first use
        // and the client would write through a dangling vtable (general-protection fault).
        self.rdz.?.conn = connection;
        self.rdz.?.reader = connection.reader(utils.io, &self.rdz.?.rbuf);
        self.rdz.?.writer = connection.writer(utils.io, &self.rdz.?.wbuf);

        self.redis = rdzClient.init(utils.io, &self.rdz.?.reader.interface, &self.rdz.?.writer.interface, .{
            .user = null,
            .pass = password,
        }) catch |err| {
            buffer = try std.fmt.bufPrint(buffer, "redis client init failed: {any}", .{err});
            self.log.err(buffer);
            self.rdz.?.close();
            self.allocator.destroy(self.rdz.?);
            self.rdz = null;
            if (attempt < max_retries) {
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            return error.RedisConnectFailed;
        };

        // Verify the connection with a PING round-trip before declaring success.
        const ping = self.redis.?.sendAlloc([]u8, self.allocator, .{"ping"}) catch |err| {
            buffer = try std.fmt.bufPrint(buffer, "redis ping failed: {any}", .{err});
            self.log.err(buffer);
            self.rdz.?.close();
            self.allocator.destroy(self.rdz.?);
            self.rdz = null;
            self.redis = null;
            if (attempt < max_retries) {
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            return error.RedisConnectFailed;
        };
        self.allocator.free(ping);
        // Mirror the connected client into `rdz` so every Redis consumer
        // (KV, rate limiter, health probe) locks the same `rdz.mu` around the
        // one shared socket
        self.rdz.?.client = self.redis.?;
        // Capture reconnect parameters so a dead socket can be rebuilt in place.
        self.rdz.?.addr = addr;
        self.rdz.?.pass = password;
        break;
    }

    buffer = try std.fmt.bufPrint(buffer, "connected to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    self.log.info(buffer);

    // Auto-register a Redis dependency health probe so /.well-known/health
    // reflects cache availability without a manual check.
    try self.addHealthCheckEntry("redis", redisHealthCheck);

    // expose Redis through the unified KV store interface (default store)
    const redisStore = try root.kvstore.build(self, .redis, .{});
    try self.kvStores.put("cache", redisStore);
    if (self.defaultKV == null) {
        self.defaultKV = redisStore;
    }
}

fn loadSQL(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const dialect = self.config.get("DB_DIALECT");
    if (std.mem.eql(u8, dialect, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "database is disabled, as dialect is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, dialect, "sqlite") == true) {
        try self.loadSQLite();
        return;
    }

    if (std.mem.eql(u8, dialect, "duckdb") == true) {
        // In-process DuckDB is wired by `loadDuckDB` via `DUCKDB_PATH`, not the
        // network Postgres path below, so skip the connection attempt here.
        return;
    }

    if (std.mem.eql(u8, dialect, "duckgres") == true) {
        try self.loadDuckGres();
        return;
    }

    if (std.mem.eql(u8, dialect, "mysql") == true) {
        try self.loadMySQL();
        return;
    }

    // Supabase is a managed Postgres instance; reuse the postgres backend but
    // read connection params from the `SUPABASE_DB_*` namespace (with sensible
    // defaults) so users don't have to also set the generic `DB_*` keys.
    const is_supabase = std.mem.eql(u8, dialect, "supabase");
    const eff_dialect = if (is_supabase) "postgres" else dialect;

    var hostname: []const u8 = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_HOST", "")
    else
        self.config.get("DB_HOST");
    const port: []const u8 = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_PORT", "5432")
    else
        self.config.get("DB_PORT");
    const user: []const u8 = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_USER", "postgres")
    else
        self.config.get("DB_USER");
    const password: []const u8 = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_PASSWORD", "")
    else
        self.config.get("DB_PASSWORD");
    const db: []const u8 = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_NAME", "postgres")
    else
        self.config.get("DB_NAME");

    if (is_supabase and hostname.len == 0) {
        const proj = self.config.getOrDefault("SUPABASE_DB_PROJECT", "");
        if (proj.len == 0) {
            buffer = try std.fmt.bufPrint(buffer, "connection to supabase failed: SUPABASE_DB_HOST or SUPABASE_DB_PROJECT is required.", .{});
            self.log.err(buffer);
            return;
        }
        hostname = try std.fmt.allocPrint(self.allocator, "db.{s}.supabase.co", .{proj});
    }

    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: host name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database port is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: user name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database password is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const sslMode = if (is_supabase)
        self.config.getOrDefault("SUPABASE_DB_SSL_MODE", "require")
    else
        self.config.getOrDefault("DB_SSL_MODE", "disable");

    var config = root.SQL.dbConfig{
        .databaseName = db,
        .dialect = eff_dialect,
        .hostname = hostname,
        .port = port,
        .username = user,
        .password = password,
        .sslMode = sslMode,
    };

    self.SQL = try root.SQL.create(
        self.allocator,
        &config,
        self.log,
        self.metricz,
    );

    self.SQL.?.allocator = self.allocator;

    const dbPort: u16 = try std.fmt.parseInt(u16, port, 10);

    var tlsMode: pgz.Conn.Opts.TLS = .off;
    if (std.mem.eql(u8, sslMode, "require")) {
        tlsMode = .require;
    } else if (std.mem.eql(u8, sslMode, "verify-ca") or
        std.mem.eql(u8, sslMode, "verify-full") or
        std.mem.eql(u8, sslMode, "verify_full") or
        std.mem.eql(u8, sslMode, "verifyca") or
        std.mem.eql(u8, sslMode, "verifyfull"))
    {
        const rootCa = self.config.get("DB_TLS_ROOT_CA");
        if (std.mem.eql(u8, rootCa, "")) {
            tlsMode = .{ .verify_full = null };
        } else {
            tlsMode = .{ .verify_full = rootCa };
        }
    }

    // Pool size + connection/acquire timeout are configurable (defaults 10 / 10s).
    const pool_size: u16 = @intCast(blk: {
        const v = self.config.getAsInt("PG_POOL_SIZE") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_SIZE else @as(u32, v);
    });
    const acquire_timeout_ms: u32 = blk: {
        const v = self.config.getAsInt("PG_POOL_ACQUIRE_TIMEOUT_MS") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS else @as(u32, v);
    };
    const options: pgz.Pool.Opts = .{
        .size = pool_size,
        .connect = .{
            .host = hostname,
            .port = dbPort,
            .tls = tlsMode,
        },
        .auth = .{
            .application_name = self.config.get("APP_NAME"),
            .username = user,
            .password = password,
            .database = db,
            .timeout = acquire_timeout_ms,
        },
    };

    self.SQL.?.sql = pgz.Pool.init(utils.io, self.allocator, options) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        return err;
    };
    // reference metricz
    self.SQL.?.metricz = self.metricz;

    self.wireDatasource(self.SQL, .postgres);

    buffer = try std.fmt.bufPrint(buffer, "generating database connection string for {s}", .{dialect});
    self.log.info(buffer);

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(
        buffer,
        "connected to {s} user to {s} database at '{s}:{s}'{s}",
        .{ user, db, hostname, port, if (tlsMode != .off) " (tls)" else "" },
    );
    self.log.info(buffer);

    // Auto-register a SQL dependency health probe so /.well-known/health reflects
    // DB availability without the user adding a manual check.
    try self.registerSqlHealth();
}

fn loadSQLite(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const dbPath = self.config.get("SQLITE_PATH");
    if (std.mem.eql(u8, dbPath, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "sqlite is disabled, as sqlite path is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const sqlite_create = self.config.getAsBool("SQLITE_CREATE");
    const sqlite_write = self.config.getAsBool("SQLITE_WRITE");
    const threading = self.config.get("SQLITE_THREADING");

    const threading_mode = if (std.mem.eql(u8, threading, "multi-thread"))
        root.sqlitez.ThreadingMode.MultiThread
    else if (std.mem.eql(u8, threading, "single-thread"))
        root.sqlitez.ThreadingMode.SingleThread
    else if (std.mem.eql(u8, threading, "serialized"))
        root.sqlitez.ThreadingMode.Serialized
    else
        root.sqlitez.ThreadingMode.MultiThread;

    self.SQLite = try root.SQLite.init(
        self.allocator,
        dbPath,
        sqlite_create,
        sqlite_write,
        threading_mode,
        self.log,
        self.metricz,
    );

    self.wireDatasource(self.SQLite, .sqlite);

    buffer = try std.fmt.bufPrint(buffer, "connected to sqlite at '{s}'", .{dbPath});
    self.log.info(buffer);

    // Auto-register a SQL (sqlite) dependency health probe.
    try self.registerSqlHealth();
}

// Auto-wire the in-process OLAP SQL engine (DuckDB) when DUCKDB_PATH is set.
// Defaults to an in-memory database when the path is empty. The shared library
// (`libs/libduckdb.so`) is linked at build time, so this adds no runtime dep.
fn loadDuckDB(self: *Self) !void {
    if (comptime !build_options.duckdb) return;
    if (self.DuckDB != null) return;
    const path = self.config.get("DUCKDB_PATH");
    if (path.len == 0) return;

    const db = try root.DuckDB.create(self.allocator, path);
    self.DuckDB = db;
    self.wireDatasource(db, .duckdb);

    const msg = try std.fmt.allocPrint(
        self.bootstrap,
        "connected to duckdb at '{s}'",
        .{if (path.len == 0) ":memory:" else path},
    );
    defer self.bootstrap.free(msg);
    self.log.info(msg);

    // Auto-register a SQL (duckdb) dependency health probe.
    try self.registerSqlHealth();
}

// Auto-wire the wired (network) DuckDB client when DB_DIALECT=duckgres is set.
// It reuses the shared DB_* connection configuration (host/port/user/password/
// database/TLS) and speaks the Postgres wire protocol to a DuckDB PG-wire
// front-end (e.g. duckgres / PostDuck), so the duckdb C library stays out of the
// link. SQL is sent verbatim in the DuckDB dialect; `pgz` is dialect-agnostic at
// the protocol layer. Exposed on the request context as `ctx.SQL` via the
// `duckgres` dialect. Disabled (returns early) when the dialect is unset, so a
// default startup with no dialect is unaffected.
fn loadDuckGres(self: *Self) !void {
    if (self.DuckGres != null) return;

    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    const hostname = self.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to duckgres failed: host name is empty.", .{});
        self.log.err(buffer);
        return;
    }
    const port = self.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to duckgres failed: database port is empty.", .{});
        self.log.err(buffer);
        return;
    }
    // DuckDB PG-wire front-ends (e.g. duckgres / PostDuck) typically require no
    // password and accept any username/database, so these are optional and
    // defaulted rather than hard-failing the wiring. Only host/port are required.
    const user = if (std.mem.eql(u8, self.config.get("DB_USER"), "")) "duckdb" else self.config.get("DB_USER");
    const password = self.config.get("DB_PASSWORD");
    const db = if (std.mem.eql(u8, self.config.get("DB_NAME"), "")) "main" else self.config.get("DB_NAME");

    const portInt = try self.config.getAsInt("DB_PORT");
    const dbPort: u16 = @intCast(portInt);

    const sslMode = self.config.getOrDefault("DB_SSL_MODE", "disable");
    var tlsMode: pgz.Conn.Opts.TLS = .off;
    if (std.mem.eql(u8, sslMode, "require")) {
        tlsMode = .require;
    } else if (std.mem.eql(u8, sslMode, "verify-ca") or
        std.mem.eql(u8, sslMode, "verify-full") or
        std.mem.eql(u8, sslMode, "verifyca") or
        std.mem.eql(u8, sslMode, "verifyfull"))
    {
        const rootCa = self.config.get("DB_TLS_ROOT_CA");
        if (std.mem.eql(u8, rootCa, "")) {
            tlsMode = .{ .verify_full = null };
        } else {
            tlsMode = .{ .verify_full = rootCa };
        }
    }

    const pool_size: u16 = @intCast(blk: {
        const v = self.config.getAsInt("PG_POOL_SIZE") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_SIZE else @as(u32, v);
    });
    const acquire_timeout_ms: u32 = blk: {
        const v = self.config.getAsInt("PG_POOL_ACQUIRE_TIMEOUT_MS") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS else @as(u32, v);
    };
    const options: pgz.Pool.Opts = .{
        .size = pool_size,
        .connect = .{
            .host = hostname,
            .port = dbPort,
            .tls = tlsMode,
        },
        .auth = .{
            .application_name = self.config.get("APP_NAME"),
            .username = user,
            .password = password,
            .database = db,
            .timeout = acquire_timeout_ms,
        },
    };

    const dg = root.DuckGres.create(self.allocator, options, self.log, self.metricz) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        return err;
    };
    self.DuckGres = dg;
    self.wireDatasource(dg, .duckgres);

    buffer = try std.fmt.bufPrint(buffer, "connected to duckgres (wired) user to {s} database at '{s}:{s}'", .{ user, hostname, port });
    self.log.info(buffer);

    try self.registerSqlHealth();
}

// Auto-wire the MySQL / MariaDB backend (pure-Zig text-protocol client; see
// `mysql.zig`). No native driver / C library is required.
fn loadMySQL(self: *Self) !void {
    if (self.MySQL != null) return;

    var buffer: []u8 = undefined;
    buffer = try self.bootstrap.alloc(u8, 512);

    // MySQL reuses the shared `DB_*` SQL credentials (only one SQL dialect is
    // active per process); its TLS/pool settings use the `MYSQL_*` prefix.
    const hostname = self.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: host name is empty.", .{});
        self.log.err(buffer);
        return;
    }
    const port = self.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: database port is empty.", .{});
        self.log.err(buffer);
        return;
    }
    const user = self.config.get("DB_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: user name is empty.", .{});
        self.log.err(buffer);
        return;
    }
    const password = self.config.get("DB_PASSWORD");
    const db = self.config.get("DB_NAME");
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: database name is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const portInt = try self.config.getAsInt("DB_PORT");
    const dbPort: u16 = @intCast(portInt);

    const ssl_mode = parseMySqlSslMode(self.config.getOrDefault("MYSQL_SSL_MODE", "disabled"));
    const ssl_ca = if (std.mem.eql(u8, self.config.get("MYSQL_SSL_CA"), ""))
        null
    else
        self.config.get("MYSQL_SSL_CA");
    const pool_size = self.config.getAsInt("MYSQL_POOL_SIZE") catch 10;

    // The pool defers all socket connections until first use (lazy connect), so
    // this runs safely during `container.create` (before the io loop) and works
    // for hostname-based configs that need async DNS.
    const m = root.MySQL.create(self.allocator, utils.io, .{
        .host = hostname,
        .port = dbPort,
        .user = user,
        .password = password,
        .database = db,
        .ssl_mode = ssl_mode,
        .ssl_ca = ssl_ca,
        .max = @intCast(pool_size),
    }) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to create mysql pool: {}", .{err});
        self.log.err(buffer);
        return;
    };
    self.MySQL = m;
    self.wireDatasource(m, .mysql);

    buffer = try std.fmt.bufPrint(buffer, "configured mysql pool (size {d}) for user '{s}' at '{s}:{s}'", .{ pool_size, user, hostname, port });
    self.log.info(buffer);

    try self.addHealthCheckEntry("mysql", mysqlHealthCheck);
}

// Resolve the `MYSQL_SSL_MODE` env value to the client's `SslMode`. Unknown
// values (and the empty default) fall back to `disabled`.
fn parseMySqlSslMode(s: []const u8) root.MySQL.SslMode {
    if (std.mem.eql(u8, s, "preferred")) return .preferred;
    if (std.mem.eql(u8, s, "required")) return .required;
    return .disabled;
}

// Probes MySQL connectivity for the health endpoint by checking out a pooled
// connection and running a trivial `SELECT 1`. The checkout is lazy, so it
// establishes a connection on first use.
fn mysqlHealthCheck(c: *container) anyerror!void {
    if (c.MySQL) |m| {
        const conn = try m.acquireConn();
        defer m.releaseConn(conn);
        _ = conn.exec("SELECT 1", .{}) catch return error.DatasourceUnavailable;
        return;
    }
    return error.DatasourceUnavailable;
}

// Auto-wire the columnar OLAP SQL engine (ClickHouse) over HTTP when
// CLICKHOUSE_URL is set. No native driver / C library is required; every
// query travels over the framework's `zul` HTTP client.
fn loadClickhouse(self: *Self) !void {
    const url = self.config.get("CLICKHOUSE_URL");
    if (std.mem.eql(u8, url, "")) {
        self.log.debug("clickhouse is disabled, as CLICKHOUSE_URL is not provided.");
        return;
    }

    const db = try root.ClickHouse.create(self.allocator, .{
        .url = url,
        .database = self.config.get("CLICKHOUSE_DB"),
        .user = if (std.mem.eql(u8, self.config.get("CLICKHOUSE_USER"), "")) null else self.config.get("CLICKHOUSE_USER"),
        .password = if (std.mem.eql(u8, self.config.get("CLICKHOUSE_PASSWORD"), "")) null else self.config.get("CLICKHOUSE_PASSWORD"),
    });
    self.ClickHouse = db;
    self.wireDatasource(db, .clickhouse);

    const msg = try std.fmt.allocPrint(self.bootstrap, "connected to clickhouse at '{s}' (db '{s}')", .{ url, self.config.get("CLICKHOUSE_DB") });
    defer self.bootstrap.free(msg);
    self.log.info(msg);

    // Auto-register a SQL (clickhouse) dependency health probe.
    try self.addHealthCheckEntry("sql", clickhouseHealthCheck);
}

// Auto-wire the time-series datasource when INFLUXDB_URL is set. The database
// (`bucket`) is required; token is optional (auth disabled).
fn loadTimeseries(self: *Self) !void {
    const url = self.config.get("INFLUXDB_URL");
    if (std.mem.eql(u8, url, "")) {
        self.log.debug("time-series is disabled, as INFLUXDB_URL is not provided.");
        return;
    }

    const bucket = self.config.get("INFLUXDB_BUCKET");
    if (std.mem.eql(u8, bucket, "")) {
        self.log.err("time-series connection failed: INFLUXDB_BUCKET must be set.");
        return;
    }

    const token = self.config.get("INFLUXDB_TOKEN");
    if (std.mem.eql(u8, token, "")) {
        self.log.err("time-series connection failed: INFLUXDB_TOKEN must be set.");
        return;
    }

    const handle = try root.Timeseries.build(self, .influxdb, .{
        .url = url,
        .bucket = bucket,
        .token = token,
    });

    self.Timeseries = handle;

    self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to influxdb at '{s}' (db '{s}')", .{ url, bucket }));
}

// Auto-wire the OpenTSDB time-series backend when OPENTSDB_URL is set.
fn loadTimeseriesOpenTSDB(self: *Self) !void {
    const url = self.config.get("OPENTSDB_URL");
    if (std.mem.eql(u8, url, "")) {
        self.log.debug("opentsdb is disabled, as OPENTSDB_URL is not provided.");
        return;
    }

    const token = self.config.get("OPENTSDB_TOKEN");
    const handle = try root.Timeseries.build(self, .opentsdb, .{
        .url = url,
        .bucket = "",
        .token = if (std.mem.eql(u8, token, "")) null else token,
    });

    self.Timeseries = handle;
    self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to opentsdb at '{s}'", .{url}));
}

// Auto-wire the search datasource when SOLR_URL or MEILI_HOST is set.
fn loadSearch(self: *Self) !void {
    // Meilisearch takes priority when configured.
    const meili_host = self.config.get("MEILI_HOST");
    if (!std.mem.eql(u8, meili_host, "")) {
        const index = self.config.get("MEILI_INDEX");
        if (std.mem.eql(u8, index, "")) {
            self.log.err("search connection failed: MEILI_INDEX must be set.");
            return;
        }

        const key = self.config.get("MEILI_API_KEY");
        const handle = try root.Search.build(self, .meilisearch, .{
            .url = meili_host,
            .default_collection = index,
            .api_key = if (std.mem.eql(u8, key, "")) null else key,
        });

        self.Search = handle;
        self.log.info(try std.fmt.allocPrint(
            self.bootstrap,
            "connected to meilisearch at '{s}' (index '{s}')",
            .{ meili_host, index },
        ));

        return;
    }

    const url = self.config.get("SOLR_URL");
    if (std.mem.eql(u8, url, "")) {
        self.log.debug("search is disabled, as SOLR_URL is not provided.");

        return;
    }

    const collection = self.config.get("SOLR_DEFAULT_COLLECTION");
    if (std.mem.eql(u8, collection, "")) {
        self.log.err("search connection failed: SOLR_DEFAULT_COLLECTION must be set.");

        return;
    }

    const auth_val = self.config.get("SOLR_BASIC_AUTH");
    const handle = try root.Search.build(self, .solr, .{
        .url = url,
        .default_collection = collection,
        .basic_auth = if (std.mem.eql(u8, auth_val, "")) null else auth_val,
    });
    self.Search = handle;

    self.log.info(try std.fmt.allocPrint(
        self.bootstrap,
        "connected to solr at '{s}' (default collection '{s}')",
        .{ url, collection },
    ));
}

// Auto-wire the NoSQL datasource when CASSANDRA_CONTACT_POINTS or
// COUCHBASE_CONTACT_POINTS is set.
fn loadNoSQL(self: *Self) !void {
    const cassandra_cp = self.config.get("CASSANDRA_CONTACT_POINTS");
    if (!std.mem.eql(u8, cassandra_cp, "")) {
        const keyspace = self.config.get("CASSANDRA_KEYSPACE");
        if (std.mem.eql(u8, keyspace, "")) {
            self.log.err("nosql connection failed: CASSANDRA_KEYSPACE must be set.");
            return;
        }

        const user_val = self.config.get("CASSANDRA_USER");
        const pass_val = self.config.get("CASSANDRA_PASSWORD");
        const tls_enabled = self.config.getAsBool("CASSANDRA_TLS_ENABLED");
        const tls_verify = self.config.getAsBool("CASSANDRA_TLS_VERIFY");
        const tls_ca = self.config.get("CASSANDRA_TLS_CA");
        const tls_server_name = self.config.get("CASSANDRA_TLS_SERVER_NAME");
        const tls_cert_file = self.config.get("CASSANDRA_TLS_CERT_FILE");
        const tls_key_file = self.config.get("CASSANDRA_TLS_KEY_FILE");

        const handle = try root.NoSQL.build(self, .cassandra, .{
            .contact_points = cassandra_cp,
            .keyspace = keyspace,
            .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
            .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
            .tls_enabled = tls_enabled,
            .tls_verify = tls_verify,
            .tls_ca_path = if (std.mem.eql(u8, tls_ca, "")) null else tls_ca,
            .tls_server_name = if (std.mem.eql(u8, tls_server_name, "")) null else tls_server_name,
            .tls_cert_file = if (std.mem.eql(u8, tls_cert_file, "")) null else tls_cert_file,
            .tls_key_file = if (std.mem.eql(u8, tls_key_file, "")) null else tls_key_file,
        });

        self.NoSQL = handle;
        self.nosql_backend = .cassandra;
        self.log.info(try std.fmt.allocPrint(
            self.bootstrap,
            "connected to cassandra at '{s}' (keyspace '{s}'){s}",
            .{ cassandra_cp, keyspace, if (tls_enabled) " (tls)" else "" },
        ));

        return;
    }

    const couchbase_cp = self.config.get("COUCHBASE_CONTACT_POINTS");
    if (!std.mem.eql(u8, couchbase_cp, "")) {
        const bucket = self.config.get("COUCHBASE_BUCKET");
        if (std.mem.eql(u8, bucket, "")) {
            self.log.err("nosql connection failed: COUCHBASE_BUCKET must be set.");
            return;
        }

        const user_val = self.config.get("COUCHBASE_USER");
        const pass_val = self.config.get("COUCHBASE_PASSWORD");
        const handle = try root.NoSQL.build(self, .couchbase, .{
            .contact_points = couchbase_cp,
            .keyspace = bucket,
            .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
            .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
        });

        self.NoSQL = handle;
        self.nosql_backend = .couchbase;
        self.log.info(try std.fmt.allocPrint(
            self.bootstrap,
            "connected to couchbase at '{s}' (bucket '{s}') via N1QL/HTTP",
            .{ couchbase_cp, bucket },
        ));

        return;
    }

    const mongo_cp = self.config.get("MONGODB_CONTACT_POINTS");
    if (!std.mem.eql(u8, mongo_cp, "")) {
        const mongo_db = self.config.get("MONGODB_DB");
        if (std.mem.eql(u8, mongo_db, "")) {
            self.log.err("nosql connection failed: MONGODB_DB must be set.");
            return;
        }

        const mongo_user = self.config.get("MONGODB_USER");
        const mongo_pass = self.config.get("MONGODB_PASSWORD");
        const mongo_tls = std.mem.eql(u8, self.config.get("MONGODB_TLS"), "true");
        const mongo_verify = std.mem.eql(u8, self.config.get("MONGODB_TLS_VERIFY"), "true");
        const mongo_ca = self.config.get("MONGODB_TLS_CA");
        const mongo_auth = self.config.get("MONGODB_AUTH_SOURCE");
        const mongo_tls_sni = self.config.get("MONGODB_TLS_SERVER_NAME");
        const mongo_cert = self.config.get("MONGODB_TLS_CERT_FILE");
        const mongo_key = self.config.get("MONGODB_TLS_KEY_FILE");

        const m = root.MongoDB.create(self.allocator, .{
            .contact_points = mongo_cp,
            .user = if (std.mem.eql(u8, mongo_user, "")) "" else mongo_user,
            .pass = if (std.mem.eql(u8, mongo_pass, "")) "" else mongo_pass,
            .auth_source = if (std.mem.eql(u8, mongo_auth, "")) "admin" else mongo_auth,
            .db = mongo_db,
            .tls_enabled = mongo_tls,
            .tls_verify = mongo_verify,
            .tls_ca_path = if (std.mem.eql(u8, mongo_ca, "")) null else mongo_ca,
            .tls_server_name = if (std.mem.eql(u8, mongo_tls_sni, "")) null else mongo_tls_sni,
            .tls_cert_file = if (std.mem.eql(u8, mongo_cert, "")) null else mongo_cert,
            .tls_key_file = if (std.mem.eql(u8, mongo_key, "")) null else mongo_key,
        }) catch |err| {
            self.log.err("could not initialize mongodb backend");
            self.log.any(err);
            return;
        };

        const handle = try self.allocator.create(root.NoSQL);
        handle.* = root.NoSQL.init(m, .mongodb, null, self.metricz);
        self.NoSQL = handle;
        self.nosql_backend = .mongodb;

        self.log.info(try std.fmt.allocPrint(
            self.bootstrap,
            "connected to mongodb at '{s}' (db '{s}'){s}",
            .{ mongo_cp, mongo_db, if (mongo_tls) " (tls)" else "" },
        ));
        return;
    }

    self.log.debug("nosql is disabled, as CONTACT_POINTS are not provided.");
}

// Auto-wire the ArangoDB document backend when ARANGO_HOST is set.
fn loadNoSQLArango(self: *Self) !void {
    const host = self.config.get("ARANGO_HOST");
    if (std.mem.eql(u8, host, "")) {
        self.log.debug("arangodb is disabled, as ARANGO_HOST is not provided.");
        return;
    }

    const db = self.config.get("ARANGO_DB");
    if (std.mem.eql(u8, db, "")) {
        self.log.err("nosql connection failed: ARANGO_DB must be set.");
        return;
    }

    const user_val = self.config.get("ARANGO_USER");
    const pass_val = self.config.get("ARANGO_PASSWORD");
    const handle = try root.NoSQL.build(self, .arangodb, .{
        .contact_points = host,
        .keyspace = db,
        .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
        .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
    });

    self.NoSQL = handle;
    self.nosql_backend = .arangodb;
    self.log.info(try std.fmt.allocPrint(
        self.bootstrap,
        "connected to arangodb at '{s}' (db '{s}')",
        .{ host, db },
    ));
}

// Auto-wire the Dgraph graph backend when DGRAPH_URL is set.
fn loadGraph(self: *Self) !void {
    const url = self.config.get("DGRAPH_URL");
    if (std.mem.eql(u8, url, "")) {
        self.log.debug("graph is disabled, as DGRAPH_URL is not provided.");
        return;
    }

    const key = self.config.get("DGRAPH_API_KEY");
    const handle = try root.Graph.build(self, .dgraph, .{
        .url = url,
        .api_key = if (std.mem.eql(u8, key, "")) null else key,
    });
    self.Graph = handle;
    self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to dgraph at '{s}'", .{url}));
}

pub fn registerZeroClient(self: *Self, service: *zeroClient) !void {
    try self.services.?.put(service.name, service);
}

pub fn registerWsClient(self: *Self, name: []const u8, client: *root.wsclient.Client) !void {
    try self.wsClients.?.put(name, client);
}

fn loadFileStore(self: *Self) !void {
    const backend_name = self.config.getOrDefault("FILE_STORE_BACKEND", "local");

    if (std.mem.eql(u8, backend_name, "s3")) {
        const store = root.filestore.build(self, .s3, .{}) catch |err| {
            self.log.err("could not initialize s3 file store");
            self.log.any(err);
            return;
        };
        try self.fileStores.put("s3", store);
        if (self.defaultFileStore == null) {
            self.defaultFileStore = store;
        }
        self.log.info("connected to s3 file store");
        return;
    }

    if (std.mem.eql(u8, backend_name, "supabase")) {
        const store = root.filestore.build(self, .supabase, .{}) catch |err| {
            self.log.err("could not initialize supabase file store");
            self.log.any(err);
            return;
        };
        try self.fileStores.put("supabase", store);
        if (self.defaultFileStore == null) {
            self.defaultFileStore = store;
        }
        self.log.info("connected to supabase file store");
        return;
    }

    if (std.mem.eql(u8, backend_name, "gcs")) {
        const store = root.filestore.build(self, .gcs, .{}) catch |err| {
            self.log.err("could not initialize gcs file store");
            self.log.any(err);
            return;
        };
        try self.fileStores.put("gcs", store);
        if (self.defaultFileStore == null) {
            self.defaultFileStore = store;
        }
        self.log.info("connected to gcs file store");
        return;
    }

    const root_dir = self.config.getOrDefault("FILE_STORE_ROOT", "");
    if (std.mem.eql(u8, root_dir, "")) {
        self.log.debug("file store is disabled, as FILE_STORE_ROOT is not provided.");
        return;
    }

    const store = root.filestore.build(self, .local, .{ .root = root_dir }) catch |err| {
        self.log.err("could not initialize local file store");
        self.log.any(err);
        return;
    };

    try self.fileStores.put("local", store);
    if (self.defaultFileStore == null) {
        self.defaultFileStore = store;
    }

    self.log.info("connected to local file store");
}
