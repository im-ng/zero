const std = @import("std");
const root = @import("../zero.zig");
const build_options = @import("build_options");
const sql = @import("sql.zig");
const pubsub = @import("pubsub.zig");
const load_metricz = @import("metricz.zig");
const load_redis = @import("redis.zig");
const filestore = @import("filestore.zig");
const timeseries = @import("timeseries.zig");
const search = @import("search.zig");
const nosql = @import("nosql.zig");
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
/// Probes ClickHouse connectivity for the health endpoint via a trivial
/// `SELECT 1` over HTTP. Fails the check if the server is unreachable.
/// Probes Redis connectivity for the health endpoint via a PING round-trip.
/// Runs a single health check and returns `true` only if it succeeds.
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
    self.health_snapshot_mu.lockUncancelable(self.io);
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
    self.health_snapshot_mu.lockUncancelable(self.io);
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
        self.health_snapshot_mu.lockUncancelable(self.io);
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

/// Starts the background health refresher. Spawns a joinable thread; spawn
/// failure logs and leaves the endpoint on inline probing (correct, just not
/// hung-check-proof). The handle is kept so `stopHealthRefresher` can join it
/// before the container is freed — detaching would let the loop read freed
/// container memory during shutdown.
pub fn startHealthRefresher(self: *container) void {
    if (self.health_refresh_ms == 0) return;
    const thread = std.Thread.spawn(.{}, refresherLoop, .{self}) catch {
        self.log.err("health refresher thread failed to start; falling back to inline probing");
        return;
    };
    self.refresherThread = thread;
}

/// Stops the refresher loop and joins its thread. Safe to call once (no-op when
/// the thread was never started). Must run while the container is still alive so
/// the thread finishes reading its `health_refresh_stop` flag before we free it.
pub fn stopHealthRefresher(self: *container) void {
    self.health_refresh_stop.store(true, .release);
    if (self.refresherThread) |thread| {
        thread.join();
        self.refresherThread = null;
    }
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

// Specialized datasources (time-series / search).
Timeseries: ?*root.Timeseries = null,
Search: ?*root.Search = null,

// NoSQL datasource (document / wide-column).
NoSQL: ?*root.NoSQL = null,
nosql_backend: ?root.nosqlInterface.Backend = null,

// Graph datasource (Dgraph over its HTTP query/mutate API).
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
// Handle of the refresher thread started by `startHealthRefresher`. `null`
// until started (or when HEALTH_SNAPSHOT_REFRESH_MS=0). Kept so shutdown can
// `join` it before the container is freed; the thread reads `health_refresh_stop`
// and other container fields, so detaching it would be a use-after-free.
refresherThread: ?std.Thread = null,

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
    try load_metricz.loadMetricz(c);

    // initialize db
    try sql.loadSQL(c);
    if (c.SQL != null or c.MySQL != null or c.SQLite != null or
        c.DuckDB != null or c.ClickHouse != null or c.DuckGres != null)
    {
        // A failed registration would silently remove the default datasource
        // from named lookup; fail startup instead of serving a broken app.
        try c.sqlStores.put("default", c.datasource);
    }

    // initialize kv
    try load_redis.loadRedis(c);

    // initialize file store (local backend auto-registered from FILE_STORE_ROOT)
    try filestore.loadFileStore(c);

    // initialize sqlite
    try sql.loadSQLite(c);

    // initialize duckdb (in-process OLAP SQL) when configured
    try sql.loadDuckDB(c);

    // initialize duckgres (wired DuckDB over the Postgres wire protocol) when
    // DB_DIALECT=duckgres is set; shares the DB_* connection configuration.
    // try sql.loadDuckGres(c);

    // initialize clickhouse (columnar OLAP SQL over HTTP) when configured
    try sql.loadClickhouse(c);

    // initialize specialized datasources (time-series / search) when configured
    try timeseries.loadTimeseries(c);

    try timeseries.loadTimeseriesOpenTSDB(c);

    try search.loadSearch(c);

    // initialize nosql datasource (document / wide-column) when configured
    try nosql.loadNoSQL(c);

    try nosql.loadNoSQLArango(c);

    // initialize graph datasource (Dgraph) when configured
    try nosql.loadGraph(c);

    // initilize message queues
    try pubsub.loadPubSub(c);
    if (c.pubSub != null) {
        try c.pubSubBackends.put("default", c.pubSub.?);
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
    // structures. The unified PubSub wrapper is heap-allocated in
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
    if (self.SQL) |s| {
        s.deinit();
        allocator.destroy(s);
    }

    // MySQL datasource: closes the pooled connections and frees the struct
    // allocated by `loadMySQL` / `MySQL.create`. `MySQL.deinit` frees the struct
    // itself, so no separate `allocator.destroy` is needed here.
    if (self.MySQL) |m| {
        m.deinit();
    }

    // SQLite datasource: closes every pooled connection and frees the struct
    // allocated by `loadSQLite` / `SQLite.init` (deinit frees it itself).
    if (self.SQLite) |sqlite| {
        sqlite.deinit();
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

    // The last published health snapshot is the only buffer `publishHealthSnapshot`
    // never frees (it only releases the *previous* one), so release it here or the
    // DebugAllocator reports it leaked at process exit.
    if (self.health_snapshot) |snap| {
        allocator.free(snap);
        self.health_snapshot = null;
    }

    allocator.destroy(self);
}

/// Set one rdkafka config option. Returns true if rdkafka rejected it, so the
/// caller can decide whether to abort (fatal) or continue (best-effort). Logs
/// the rdkafka-provided error into `log_buf`.
/// Wire a datasource pointer into the container with an optional circuit breaker.
/// Shared by every `load*` backend so the breaker-conditional isn't duplicated.
/// Register the shared SQL health probe used by postgres/sqlite/duckdb.
pub fn natsPullWaitMs(self: *Self) u32 {
    return @intCast(self.config.getAsInt("NATS_MAX_PULL_WAIT") catch constants.DEFAULT_NATS_MAX_PULL_WAIT_MS);
}

// Auto-wire the in-process OLAP SQL engine (DuckDB) when DUCKDB_PATH is set.
// Defaults to an in-memory database when the path is empty. The shared library
// (`libs/libduckdb.so`) is linked at build time, so this adds no runtime dep.

// Auto-wire the wired (network) DuckDB client when DB_DIALECT=duckgres is set.
// It reuses the shared DB_* connection configuration (host/port/user/password/
// database/TLS) and speaks the Postgres wire protocol to a DuckDB PG-wire
// front-end (e.g. duckgres / PostDuck), so the duckdb C library stays out of the
// link. SQL is sent verbatim in the DuckDB dialect; `pgz` is dialect-agnostic at
// the protocol layer. Exposed on the request context as `ctx.SQL` via the
// `duckgres` dialect. Disabled (returns early) when the dialect is unset, so a
// default startup with no dialect is unaffected.

// Auto-wire the MySQL / MariaDB backend (pure-Zig text-protocol client; see
// `mysql.zig`). No native driver / C library is required.

// Resolve the `MYSQL_SSL_MODE` env value to the client's `SslMode`. Unknown
// values (and the empty default) fall back to `disabled`.

// Probes MySQL connectivity for the health endpoint by checking out a pooled
// connection and running a trivial `SELECT 1`. The checkout is lazy, so it
// establishes a connection on first use.

// Auto-wire the columnar OLAP SQL engine (ClickHouse) over HTTP when
// CLICKHOUSE_URL is set. No native driver / C library is required; every
// query travels over the framework's `zul` HTTP client.

// Auto-wire the time-series datasource when INFLUXDB_URL is set. The database
// (`bucket`) is required; token is optional (auth disabled).

// Auto-wire the OpenTSDB time-series backend when OPENTSDB_URL is set.

// Auto-wire the search datasource when SOLR_URL or MEILI_HOST is set.

// Auto-wire the NoSQL datasource when CASSANDRA_CONTACT_POINTS or
// COUCHBASE_CONTACT_POINTS is set.

// Auto-wire the ArangoDB document backend when ARANGO_HOST is set.

// Auto-wire the Dgraph graph backend when DGRAPH_URL is set.

pub fn registerZeroClient(self: *Self, service: *zeroClient) !void {
    try self.services.?.put(service.name, service);
}

pub fn registerWsClient(self: *Self, name: []const u8, client: *root.wsclient.Client) !void {
    try self.wsClients.?.put(name, client);
}
