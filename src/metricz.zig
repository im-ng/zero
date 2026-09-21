const std = @import("std");
const root = @import("zero.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Self = @This();
const metricz = @This();
const pgz = root.pgz;
const metrics = root.httpz.metriks;
const Context = root.Context;
const Process = root.process;
const utils = root.utils;

const AppInfoLabel = struct { app_name: []const u8, app_version: []const u8, zero_version: []const u8 };

const AppThreadsourceLabel = struct { label: []const u8 };
const AppMemoryUsageLabel = struct { label: []const u8 };
const AppMemoryTotalLabel = struct { label: []const u8 };

pub const AppHttpResponseLatencyLabel = struct { method: []const u8, path: []const u8, status: u16 };
pub const AppHttpResponseHitLabel = struct { method: []const u8, path: []const u8, status: u16 };

pub const AppSQLStatsLabel = struct { hostname: []const u8, database: []const u8, query: []const u8, operation: []const u8 };

// external service response metric labels
pub const ServiceResponseLabel = struct { method: []const u8, path: []const u8, status: u16 };

// pubsub metrics labels
pub const PubSubPublisherTotalLabel = struct { topic: []const u8 };
pub const PubSubPublisherSuccessLabel = struct { topic: []const u8 };

pub const PubSubSubscriberTotalLabel = struct { topic: []const u8, consumer: []const u8 };
pub const PubSubSubscriberSuccessLabel = struct { topic: []const u8, consumer: []const u8 };

// failure metrics labels
pub const CircuitOpenLabel = struct { name: []const u8 };
pub const PubSubDLQLabel = PubSubSubscriberTotalLabel;

// Type-erased handle for an app-registered custom metric. The metrics library
// has no global registry, so custom metrics are kept in a dynamic list and
// written alongside the built-ins. `ptr` points at the heap-allocated metric
// `Impl`; `write` casts it back and serializes it, `deinit` frees it.
pub const CustomMetric = struct {
    ptr: *anyopaque,
    write: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,
    deinit: *const fn (*anyopaque) void,
};

// Returns a writer shim for a concrete metric `Impl` type.
fn writeCustom(comptime ImplT: type) *const fn (*anyopaque, *std.Io.Writer) anyerror!void {
    return struct {
        fn f(ptr: *anyopaque, w: *std.Io.Writer) !void {
            const m = @as(*ImplT, @ptrCast(@alignCast(ptr)));
            try m.write(w);
        }
    }.f;
}

// Returns a destructor shim for a concrete metric `Impl` type. It calls the
// metric's own `.deinit()` (which frees its label strings / hashmaps) and then
// releases the `allocator.create(ImplT)` backing pointer.
fn deinitCustom(comptime ImplT: type) *const fn (*anyopaque) void {
    return struct {
        fn f(ptr: *anyopaque) void {
            const m = @as(*ImplT, @ptrCast(@alignCast(ptr)));
            m.deinit();
            const allocator = m.allocator;
            allocator.destroy(m);
        }
    }.f;
}

custom: std.array_list.Managed(CustomMetric) = undefined,
mut: std.Io.Mutex = .init,

Info: metrics.CounterVec(
    u32,
    AppInfoLabel,
).Impl,

Threads: metrics.GaugeVec(
    u64,
    AppThreadsourceLabel,
).Impl,

MemoryUsage: metrics.GaugeVec(
    u64,
    AppMemoryUsageLabel,
).Impl,

MemoryTotal: metrics.GaugeVec(
    u64,
    AppMemoryTotalLabel,
).Impl,

ResponseBucket: metrics.HistogramVec(
    f64,
    AppHttpResponseLatencyLabel,
    &.{
        0.001,
        0.003,
        0.005,
        0.01,
        0.02,
        0.03,
        0.05,
        0.1,
        0.2,
        0.3,
        0.5,
        0.75,
        1,
        2,
        3,
        5,
        10,
        30,
    },
).Impl,

ResponseBucketHits: metrics.CounterVec(
    u64,
    AppHttpResponseHitLabel,
).Impl,

ServiceResponseBucket: metrics.HistogramVec(
    f64,
    ServiceResponseLabel,
    &.{
        0.001,
        0.003,
        0.005,
        0.01,
        0.02,
        0.03,
        0.05,
        0.1,
        0.2,
        0.3,
        0.5,
        0.75,
        1,
        2,
        3,
        5,
        10,
        30,
    },
).Impl,

SQLBucket: metrics.HistogramVec(
    f64,
    AppSQLStatsLabel,
    &.{
        0.001,
        0.003,
        0.005,
        0.01,
        0.02,
        0.03,
        0.05,
        0.1,
        0.2,
        0.3,
        0.5,
        0.75,
        1,
        2,
        3,
        5,
        10,
        30,
    },
).Impl,

PubSubPublisherTotal: metrics.CounterVec(
    u64,
    PubSubPublisherTotalLabel,
).Impl,

PubSubPublisherSuccess: metrics.CounterVec(
    u64,
    PubSubPublisherSuccessLabel,
).Impl,

PubSubSubscriberTotal: metrics.CounterVec(
    u64,
    PubSubSubscriberTotalLabel,
).Impl,

PubSubSubscriberSuccess: metrics.CounterVec(
    u64,
    PubSubSubscriberSuccessLabel,
).Impl,

// failure metrics
CircuitOpenTotal: metrics.CounterVec(
    u64,
    CircuitOpenLabel,
).Impl,

PubSubDLQTotal: metrics.CounterVec(
    u64,
    PubSubDLQLabel,
).Impl,

pub fn info(self: *Self, labels: AppInfoLabel) !void {
    return self.Info.incr(labels);
}

pub fn appThreads(self: *Self, labels: AppThreadsourceLabel, value: u64) !void {
    return self.Threads.set(labels, value);
}

pub fn appMemoryUsage(self: *Self, labels: AppMemoryUsageLabel, value: u64) !void {
    return self.MemoryUsage.set(labels, value);
}

pub fn appMemoryTotal(self: *Self, labels: AppMemoryTotalLabel, value: u64) !void {
    return self.MemoryTotal.set(labels, value);
}

pub fn response(self: *Self, labels: AppHttpResponseLatencyLabel, value: f32) !void {
    return self.ResponseBucket.observe(labels, value);
}

pub fn responseHits(self: *Self, labels: AppHttpResponseHitLabel, count: ?u64) !void {
    return self.ResponseBucketHits.incrBy(labels, count orelse 1);
}

pub fn clientResponse(self: *Self, labels: ServiceResponseLabel, value: f32) !void {
    return self.ServiceResponseBucket.observe(labels, value);
}

pub fn sqlResponse(self: *Self, labels: AppSQLStatsLabel, value: f32) !void {
    return self.SQLBucket.observe(labels, value);
}

pub fn publisherTotal(self: *Self, labels: PubSubPublisherTotalLabel) !void {
    return self.PubSubPublisherTotal.incr(labels);
}

pub fn publisherSuccess(self: *Self, labels: PubSubPublisherSuccessLabel) !void {
    return self.PubSubPublisherSuccess.incr(labels);
}

pub fn subscriberTotal(self: *Self, labels: PubSubSubscriberTotalLabel) !void {
    return self.PubSubSubscriberTotal.incr(labels);
}

pub fn SubscriberSuccess(self: *Self, labels: PubSubSubscriberSuccessLabel) !void {
    return self.PubSubSubscriberSuccess.incr(labels);
}

pub fn circuitOpen(self: *Self, labels: CircuitOpenLabel) !void {
    return self.CircuitOpenTotal.incr(labels);
}

pub fn dlq(self: *Self, labels: PubSubDLQLabel) !void {
    return self.PubSubDLQTotal.incr(labels);
}

/// Registers a custom counter with label struct `L` and returns the handle so
/// the caller can `incr(label)` / `incrBy(label, n)` from request handlers.
/// Appears on `/metrics` automatically.
pub fn Counter(self: *Self, comptime L: type, allocator: Allocator, comptime name: []const u8, comptime help: ?[]const u8) !*metrics.CounterVec(u64, L).Impl {
    const T = metrics.CounterVec(u64, L).Impl;
    const impl = try allocator.create(T);
    errdefer allocator.destroy(impl);
    impl.* = try T.init(allocator, utils.io, name, .{ .help = help });
    try self.addCustom(impl, writeCustom(T), deinitCustom(T));
    return impl;
}

/// Registers a custom gauge. Caller uses `set(label, value)` / `incr` / `dec`.
pub fn Gauge(self: *Self, comptime L: type, allocator: Allocator, comptime name: []const u8, comptime help: ?[]const u8) !*metrics.GaugeVec(u64, L).Impl {
    const T = metrics.GaugeVec(u64, L).Impl;
    const impl = try allocator.create(T);
    errdefer allocator.destroy(impl);
    impl.* = try T.init(allocator, name, .{ .help = help });
    try self.addCustom(impl, writeCustom(T), deinitCustom(T));
    return impl;
}

/// Registers a custom histogram with the given bucket boundaries (seconds).
/// Caller uses `observe(label, value)`.
pub fn Histogram(self: *Self, comptime L: type, allocator: Allocator, comptime name: []const u8, comptime buckets: []const f64, comptime help: ?[]const u8) !*metrics.HistogramVec(f64, L, buckets).Impl {
    const T = metrics.HistogramVec(f64, L, buckets).Impl;
    const impl = try allocator.create(T);
    errdefer allocator.destroy(impl);
    impl.* = try T.init(allocator, utils.io, name, .{ .help = help });
    try self.addCustom(impl, writeCustom(T), deinitCustom(T));
    return impl;
}

fn addCustom(self: *Self, ptr: *anyopaque, write_fn: *const fn (*anyopaque, *std.Io.Writer) anyerror!void, deinit_fn: *const fn (*anyopaque) void) !void {
    self.mut.lockUncancelable(utils.io);
    defer self.mut.unlock(utils.io);
    try self.custom.append(.{ .ptr = ptr, .write = write_fn, .deinit = deinit_fn });
}

pub fn initialize(allocator: Allocator, comptime _: metrics.RegistryOpts) !*metricz {
    metrics.setIo(utils.io);
    const m = try allocator.create(metricz);
    errdefer allocator.destroy(m);

    // `allocator.create` returns uninitialized memory; the struct's default
    // field initializers are NOT applied, so `mut` must be initialized here.
    // Without this, `writeRaw`'s `self.mut.lockUncancelable` futex-waits
    // forever on garbage state (manifesting as a hung `/metrics`).
    m.mut = .init;

    m.Info = try metrics.CounterVec(u32, AppInfoLabel).Impl
        .init(allocator, utils.io, "app_info", .{ .help = "Info for app_name, app_version and framework_version." });

    m.Threads = try metrics.GaugeVec(u64, AppThreadsourceLabel).Impl
        .init(allocator, "app_threads", .{ .help = "Info of overall app threads count." });

    m.MemoryUsage = try metrics.GaugeVec(u64, AppMemoryUsageLabel).Impl
        .init(allocator, "app_memory_usage", .{ .help = "Info of overall app memory usage." });

    m.MemoryTotal = try metrics.GaugeVec(u64, AppMemoryTotalLabel).Impl
        .init(allocator, "app_memory_total", .{ .help = "Info of overall app memory total usage." });

    m.ResponseBucket = try metrics.HistogramVec(f64, AppHttpResponseLatencyLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, utils.io, "app_http_response", .{ .help = "Response time of HTTP requests in seconds." });

    m.ResponseBucketHits = try metrics.CounterVec(u64, AppHttpResponseHitLabel).Impl
        .init(allocator, utils.io, "app_http_response_hits", .{ .help = "Response counts of HTTP requests." });

    m.ServiceResponseBucket = try metrics.HistogramVec(f64, ServiceResponseLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, utils.io, "app_http_service_response", .{ .help = "Response time of external service requests in seconds." });

    m.SQLBucket = try metrics.HistogramVec(f64, AppSQLStatsLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, utils.io, "app_sql_response", .{ .help = "Response time of sql query execution in seconds." });

    m.PubSubPublisherTotal = try metrics.CounterVec(u64, PubSubPublisherTotalLabel).Impl
        .init(allocator, utils.io, "app_pubsub_publish_total_count", .{ .help = "Total pubsub publisher counter per topic" });

    m.PubSubPublisherSuccess = try metrics.CounterVec(u64, PubSubPublisherSuccessLabel).Impl
        .init(allocator, utils.io, "app_pubsub_publish_success_count", .{ .help = "Successful pubsub publisher counter per topic" });

    m.PubSubSubscriberTotal = try metrics.CounterVec(u64, PubSubSubscriberTotalLabel).Impl
        .init(allocator, utils.io, "app_pubsub_subscriber_total_count", .{ .help = "Total pubsub subscriber counter per topic per consumer group" });

    m.PubSubSubscriberSuccess = try metrics.CounterVec(u64, PubSubSubscriberSuccessLabel).Impl
        .init(allocator, utils.io, "app_pubsub_subscriber_success_count", .{ .help = "Successful pubsub subscriber counter per topic per consumer group" });

    m.CircuitOpenTotal = try metrics.CounterVec(u64, CircuitOpenLabel).Impl
        .init(allocator, utils.io, "app_circuit_open_total", .{ .help = "Total circuit-breaker open events by downstream name." });

    m.PubSubDLQTotal = try metrics.CounterVec(u64, PubSubDLQLabel).Impl
        .init(allocator, utils.io, "app_pubsub_dlq_total", .{ .help = "Total dead-lettered messages per topic per consumer." });

    m.custom = std.array_list.Managed(CustomMetric).init(allocator);

    return m;
}

/// Frees every built-in metric vec (which in turn release their duped label
/// strings, attribute buffers, and value hashmaps), the custom metric list, and
/// the `metricz` struct itself. Safe to call only after the metrics server
/// thread has been stopped and joined (see `App.run` teardown order).
pub fn deinit(self: *Self, allocator: Allocator) void {
    self.mut.lockUncancelable(utils.io);
    defer self.mut.unlock(utils.io);

    self.Info.deinit();
    self.Threads.deinit();
    self.MemoryUsage.deinit();
    self.MemoryTotal.deinit();
    self.ResponseBucket.deinit();
    self.ResponseBucketHits.deinit();
    self.ServiceResponseBucket.deinit();
    self.SQLBucket.deinit();
    self.PubSubPublisherTotal.deinit();
    self.PubSubPublisherSuccess.deinit();
    self.PubSubSubscriberTotal.deinit();
    self.PubSubSubscriberSuccess.deinit();
    self.CircuitOpenTotal.deinit();
    self.PubSubDLQTotal.deinit();

    for (self.custom.items) |c| {
        c.deinit(c.ptr);
    }
    self.custom.deinit();

    allocator.destroy(self);
}

pub fn write(self: *Self, ctx: *Context) !void {
    return self.writeRaw(ctx.allocator, ctx.response.writer());
}

/// Writes the full metric set (app + pg + pubsub) to an arbitrary writer.
/// Used by the standalone metrics server, which has no `Context`.
pub fn writeRaw(self: *Self, allocator: Allocator, writer: *std.Io.Writer) !void {
    try self.Info.write(writer);
    if (builtin.os.tag == .linux) {
        const path = try utils.combine(allocator, "/proc/{d}/status", .{std.c.getpid()});

        const ps = try Process.usage(allocator, path);

        try self.appThreads(.{ .label = "app_threads" }, ps.threads);
        try self.appMemoryUsage(.{ .label = "app_memory_usage" }, ps.rssAnon);
        try self.appMemoryTotal(.{ .label = "app_memory_total" }, ps.vmHWM);

        try self.Threads.write(writer);
        try self.MemoryUsage.write(writer);
        try self.MemoryTotal.write(writer);
    }
    try self.ResponseBucketHits.write(writer);
    try self.ResponseBucket.write(writer);
    try self.ServiceResponseBucket.write(writer);

    try self.SQLBucket.write(writer);
    //rewrite pg metrics labelling to match with default
    try pgz.writeMetrics(writer);

    try self.PubSubPublisherTotal.write(writer);
    try self.PubSubPublisherSuccess.write(writer);
    try self.PubSubSubscriberTotal.write(writer);
    try self.PubSubSubscriberSuccess.write(writer);

    try self.CircuitOpenTotal.write(writer);
    try self.PubSubDLQTotal.write(writer);

    self.mut.lockUncancelable(utils.io);
    defer self.mut.unlock(utils.io);
    for (self.custom.items) |c| {
        try c.write(c.ptr, writer);
    }
}
