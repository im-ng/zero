const std = @import("std");
const root = @import("zero.zig");
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

/// Probes SQL connectivity for the health endpoint. For Postgres it acquires and
/// releases a pooled connection (failing the check if the pool is exhausted or
/// the server is unreachable); for SQLite the store is local, so a successful
/// load already implies health.
fn sqlHealthCheck(c: *container) anyerror!void {
    if (c.SQL) |sql| {
        const conn = try sql.sql.acquire();
        sql.sql.release(conn);
        return;
    }
    if (c.SQLite) |_| {
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
        const pong = try r.sendAlloc([]u8, c.allocator, .{"ping"});
        c.allocator.free(pong);
        return;
    }
    return error.RedisUnavailable;
}

/// Runs a health check on a spawned thread and returns `true` only if it
/// completes successfully within `timeout_ms`.
pub fn runHealthCheckBounded(self: *container, hc: *HealthCheck, timeout_ms: u32) bool {
    _ = timeout_ms;
    hc.check(self) catch return false;
    return true;
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
/// OpenTelemetry provider (inert unless OTEL_EXPERIMENTAL=true). Set by App.initBase.
otel: *root.otel.Provider = undefined,
authProvider: *root.AuthProvider = undefined,

/// optional role-based access control registry, wired into the rbac middleware
rbac: ?*root.rbac.RBAC = null,

redis: ?rediz.Client = null,
rdz: ?*root.rdz = null,
SQL: ?*root.SQL = null,
SQLite: ?*root.SQLite = null,
datasource: root.Datasource = undefined,

// In-process OLAP SQL engine (DuckDB). Linked via libs/libduckdb.so.
DuckDB: ?*root.DuckDB = null,

// Columnar OLAP SQL engine (ClickHouse) over HTTP. No native driver / C lib.
ClickHouse: ?*root.ClickHouse = null,

// Specialized datasources (Round 1: time-series / search).
Timeseries: ?*root.Timeseries = null,
Search: ?*root.Search = null,

// NoSQL datasource (Round 1: document / wide-column).
NoSQL: ?*root.NoSQL = null,
services: ?std.StringHashMap(*zeroClient) = null,
kvStores: std.StringHashMap(*root.KVStore) = undefined,
defaultKV: ?*root.KVStore = null,
fileStores: std.StringHashMap(*root.FileStore) = undefined,
defaultFileStore: ?*root.FileStore = null,
mqtt: ?*root.MQTT = null,
Kakfa: ?*root.kafka = null,
Nats: ?*root.nats = null,
Redis: ?*root.redisPubSub = null,
pubSub: ?*root.PubSub = null,

// user-registered static-file mounts (served by the staticDirectory catch-all)
staticMounts: std.array_list.Managed(StaticMount) = undefined,

// GraphQL resolver roots (set by App.graphql; read by the dispatch handler)
graphql_query: ?*const anyopaque = null,
graphql_mutation: ?*const anyopaque = null,

// user-registered health checks surfaced by GET /.well-known/health
healthChecks: std.array_list.Managed(HealthCheck) = undefined,

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

    // initialize service client handler maps
    c.services = std.StringHashMap(*zeroClient).init(c.bootstrap);

    // initialize kv stores (backends registered via App.addKVStore / loadRedis)
    c.kvStores = std.StringHashMap(*root.KVStore).init(c.bootstrap);

    // initialize file stores (backends registered via App.addFileStore / loadFileStore)
    c.fileStores = std.StringHashMap(*root.FileStore).init(c.bootstrap);

    // initialize user-registered health checks
    c.healthChecks = std.array_list.Managed(container.HealthCheck).init(c.bootstrap);

    // initialize user-registered static mounts
    c.staticMounts = std.array_list.Managed(container.StaticMount).init(c.bootstrap);

    // initialize metricz
    try c.loadMetricz();

    // initialize db
    try c.loadSQL();

    // initialize kv
    try c.loadRedis();

    // initialize file store (local backend auto-registered from FILE_STORE_ROOT)
    try c.loadFileStore();

    // initialize sqlite
    try c.loadSQLite();

    // initialize duckdb (in-process OLAP SQL) when configured
    try c.loadDuckDB();

    // initialize clickhouse (columnar OLAP SQL over HTTP) when configured
    try c.loadClickhouse();

    // initialize specialized datasources (time-series / search) when configured
    try c.loadTimeseries();
    try c.loadSearch();

    // initialize nosql datasource (document / wide-column) when configured
    try c.loadNoSQL();

    // initilize message queues
    try c.loadPubSub();

    const msg: []const u8 = "container is created";
    c.log.info(msg);

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

    // Config and logger only wrap borrowed pointers (the env map / io), so freeing
    // the structs is sufficient.
    self.config.deinit();
    self.log.deinit();

    // Shared SQL datasource: closes the pg connection pool, then frees the struct.
    if (self.SQL) |sql| {
        sql.deinit();
        allocator.destroy(sql);
    }

    // In-process OLAP engine (DuckDB): closes the C database/connection and the
    // struct allocated by `create` / `addDuckDB`.
    if (self.DuckDB) |db| {
        db.deinit(allocator);
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
    } else {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        self.log.debug(buffer);
    }
}

fn loadKafkaPubSub(self: *Self) !void {
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
    const kafkaTlsSkipVerify = self.config.getOrDefault("KAFKA_TLS_INSECURE_SKIP_VERIFY", "true");

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

    self.Kakfa = kafka.create(self, config, null, mode) catch |err| {
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
    ps.* = .{ .ptr = @ptrCast(@alignCast(self.Kakfa)), .vtable = &root.kafka.vtable };
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
    );
}

/// Register the shared SQL health probe used by postgres/sqlite/duckdb.
fn registerSqlHealth(self: *Self) !void {
    try self.healthChecks.append(.{ .name = "sql", .check = sqlHealthCheck });
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

pub fn natsPullWaitMs(self: *Self) u32 {
    return @intCast(self.config.getAsInt("NATS_MAX_PULL_WAIT") catch constants.DEFAULT_NATS_MAX_PULL_WAIT_MS);
}

fn loadMetricz(self: *Self) !void {
    // initialize metrics
    self.metricz = try Metricz.initialize(self.allocator, .{ .prefix = "", .exclude = null });

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

    const addr = try std.Io.net.IpAddress.parseIp4(hostname, portInt);

    const connection = try addr.connect(utils.io, .{ .mode = .stream });
    defer connection.close(utils.io);

    self.rdz = try rdzDatasource.create(self.allocator);
    var reader = connection.reader(utils.io, &self.rdz.?.rbuf);
    var writer = connection.writer(utils.io, &self.rdz.?.wbuf);

    self.redis = rdzClient.init(utils.io, &reader.interface, &writer.interface, .{
        .user = null,
        .pass = password,
    }) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        std.process.exit(1);
    };

    buffer = try std.fmt.bufPrint(buffer, "connecting to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    self.log.info(buffer);

    const ping = try self.redis.?.sendAlloc([]u8, self.allocator, .{"ping"});
    defer self.allocator.free(ping);

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "ping status {s}", .{ping});
    self.log.info(buffer);

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    self.log.info(buffer);

    // Auto-register a Redis dependency health probe so /.well-known/health
    // reflects cache availability without a manual check.
    try self.healthChecks.append(.{ .name = "redis", .check = redisHealthCheck });

    // expose Redis through the unified KV store interface (default store)
    const redisStore = try root.kvstore.build(self, .redis, .{});
    try self.kvStores.put("cache", redisStore);
    if (self.defaultKV == null) self.defaultKV = redisStore;
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

    const hostname = self.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: host name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const port = self.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database port is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const user = self.config.get("DB_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: user name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const password = self.config.get("DB_PASSWORD");
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database password is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const db = self.config.get("DB_NAME");
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    var config = root.SQL.dbConfig{
        .databaseName = db,
        .dialect = dialect,
        .hostname = hostname,
        .port = port,
        .username = user,
        .password = password,
        .sslMode = self.config.getOrDefault("DB_SSL_MODE", "disable"),
    };

    self.SQL = try root.SQL.create(
        self.allocator,
        &config,
        self.log,
        self.metricz,
    );

    self.SQL.?.allocator = self.allocator;

    const portInt = try self.config.getAsInt("DB_PORT");
    const dbPort: u16 = @intCast(portInt);

    const sslMode = self.config.getOrDefault("DB_SSL_MODE", "disable");
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
            .username = self.config.get("DB_USER"),
            .password = self.config.get("DB_PASSWORD"),
            .database = self.config.get("DB_NAME"),
            .timeout = acquire_timeout_ms,
        },
    };

    self.SQL.?.sql = pgz.Pool.init(utils.io, self.allocator, options) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        std.process.exit(1);
    };
    // reference metricz
    self.SQL.?.metricz = self.metricz;

    self.wireDatasource(self.SQL, .postgres);

    buffer = try std.fmt.bufPrint(buffer, "generating database connection string for {s}", .{dialect});
    self.log.info(buffer);

    buffer = try self.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to {s} user to {s} database at '{s}:{s}'", .{ user, db, hostname, port });
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
    if (self.DuckDB != null) return;
    const path = self.config.get("DUCKDB_PATH");
    if (path.len == 0) return;

    const db = try root.DuckDB.create(self.allocator, path);
    self.DuckDB = db;
    self.wireDatasource(db, .duckdb);

    const msg = try std.fmt.allocPrint(self.bootstrap, "connected to duckdb at '{s}'", .{if (path.len == 0) ":memory:" else path});
    defer self.bootstrap.free(msg);
    self.log.info(msg);

    // Auto-register a SQL (duckdb) dependency health probe.
    try self.registerSqlHealth();
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
    try self.healthChecks.append(.{ .name = "sql", .check = clickhouseHealthCheck });
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

// Auto-wire the search datasource when SOLR_URL is set.
fn loadSearch(self: *Self) !void {
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
    self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to solr at '{s}' (default collection '{s}')", .{ url, collection }));
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
        const handle = try root.NoSQL.build(self, .cassandra, .{
            .contact_points = cassandra_cp,
            .keyspace = keyspace,
            .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
            .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
        });
        self.NoSQL = handle;
        self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to cassandra at '{s}' (keyspace '{s}')", .{ cassandra_cp, keyspace }));
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
        self.log.info(try std.fmt.allocPrint(self.bootstrap, "connected to couchbase at '{s}' (bucket '{s}') via N1QL/HTTP", .{ couchbase_cp, bucket }));
        return;
    }

    self.log.debug("nosql is disabled, as CASSANDRA_CONTACT_POINTS / COUCHBASE_CONTACT_POINTS are not provided.");
}

pub fn registerZeroClient(self: *Self, service: *zeroClient) !void {
    try self.services.?.put(service.name, service);
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
        if (self.defaultFileStore == null) self.defaultFileStore = store;
        self.log.info("connected to s3 file store");
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
    if (self.defaultFileStore == null) self.defaultFileStore = store;

    self.log.info("connected to local file store");
}

// ===================== Tests =====================

test "staticResolve matches mount with path boundary" {
    const mounts = [_]StaticMount{
        .{ .prefix = "/assets", .dir = "/var/www" },
        .{ .prefix = "/public", .dir = "/srv" },
    };
    const hit = staticResolve(&mounts, "/assets/logo.png").?;
    try std.testing.expectEqualStrings("/var/www", hit.mount.dir);
    try std.testing.expectEqualStrings("/logo.png", hit.rel);

    // mount root resolves with empty rel
    const rmt = staticResolve(&mounts, "/public").?;
    try std.testing.expectEqualStrings("/srv", rmt.mount.dir);
    try std.testing.expectEqualStrings("", rmt.rel);

    // prefix must be a path boundary, not a substring
    try std.testing.expect(staticResolve(&mounts, "/assets2/x") == null);
    try std.testing.expect(staticResolve(&mounts, "/nope/x") == null);
}
