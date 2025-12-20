const std = @import("std");
const metrics = @import("metriks");
const root = @import("zero.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Self = @This();
const metricz = @This();
const pgz = root.pgz;
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

pub fn responseHits(self: *Self, labels: AppHttpResponseHitLabel) !void {
    return self.ResponseBucketHits.incr(labels);
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

pub fn initialize(allocator: Allocator, comptime _: metrics.RegistryOpts) !*metricz {
    const m = try allocator.create(metricz);
    errdefer allocator.destroy(m);

    m.Info = try metrics.CounterVec(u32, AppInfoLabel).Impl
        .init(allocator, "app_info", .{ .help = "Info for app_name, app_version and framework_version." });

    m.Threads = try metrics.GaugeVec(u64, AppThreadsourceLabel).Impl
        .init(allocator, "app_threads", .{ .help = "Info of overall app threads count." });

    m.MemoryUsage = try metrics.GaugeVec(u64, AppMemoryUsageLabel).Impl
        .init(allocator, "app_memory_usage", .{ .help = "Info of overall app memory usage." });

    m.MemoryTotal = try metrics.GaugeVec(u64, AppMemoryTotalLabel).Impl
        .init(allocator, "app_memory_total", .{ .help = "Info of overall app memory total usage." });

    m.ResponseBucket = try metrics.HistogramVec(f64, AppHttpResponseLatencyLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, "app_http_response", .{ .help = "Response time of HTTP requests in seconds." });

    m.ResponseBucketHits = try metrics.CounterVec(u64, AppHttpResponseHitLabel).Impl
        .init(allocator, "app_http_response_hits", .{ .help = "Response counts of HTTP requests." });

    m.ServiceResponseBucket = try metrics.HistogramVec(f64, ServiceResponseLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, "app_http_service_response", .{ .help = "Response time of external service requests in seconds." });

    m.SQLBucket = try metrics.HistogramVec(f64, AppSQLStatsLabel, &.{ 0.001, 0.003, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 3, 5, 10, 30 }).Impl
        .init(allocator, "app_sql_response", .{ .help = "Response time of sql query execution in seconds." });

    m.PubSubPublisherTotal = try metrics.CounterVec(u64, PubSubPublisherTotalLabel).Impl
        .init(allocator, "app_pubsub_publish_total_count", .{ .help = "Total pubsub publisher counter per topic" });

    m.PubSubPublisherSuccess = try metrics.CounterVec(u64, PubSubPublisherSuccessLabel).Impl
        .init(allocator, "app_pubsub_publish_success_count", .{ .help = "Successful pubsub publisher counter per topic" });

    m.PubSubSubscriberTotal = try metrics.CounterVec(u64, PubSubSubscriberTotalLabel).Impl
        .init(allocator, "app_pubsub_subscriber_total_count", .{ .help = "Total pubsub subscriber counter per topic per consumer group" });

    m.PubSubSubscriberSuccess = try metrics.CounterVec(u64, PubSubSubscriberSuccessLabel).Impl
        .init(allocator, "app_pubsub_subscriber_success_count", .{ .help = "Successful pubsub subscriber counter per topic per consumer group" });
    return m;
}

pub fn write(self: *Self, ctx: *Context) !void {
    // return httpz.writeMetrics(ctx.response.writer());
    try self.Info.write(ctx.response.writer());
    if (builtin.os.tag == .linux) {
        const path = try utils.combine(ctx.allocator, "/proc/{d}/status", .{std.c.getpid()});

        const ps = try Process.usage(ctx.allocator, path);

        try self.appThreads(.{ .label = "app_threads" }, ps.threads);
        try self.appMemoryUsage(.{ .label = "app_memory_usage" }, ps.rssAnon);
        try self.appMemoryTotal(.{ .label = "app_memory_total" }, ps.vmHWM);

        try self.Threads.write(ctx.response.writer());
        try self.MemoryUsage.write(ctx.response.writer());
        try self.MemoryTotal.write(ctx.response.writer());
    }
    try self.ResponseBucketHits.write(ctx.response.writer());
    try self.ResponseBucket.write(ctx.response.writer());
    try self.ServiceResponseBucket.write(ctx.response.writer());

    try self.SQLBucket.write(ctx.response.writer());
    //rewrite pg metrics labelling to match with default
    try pgz.writeMetrics(ctx.response.writer());

    try self.PubSubPublisherTotal.write(ctx.response.writer());
    try self.PubSubPublisherSuccess.write(ctx.response.writer());
    try self.PubSubSubscriberTotal.write(ctx.response.writer());
    try self.PubSubSubscriberSuccess.write(ctx.response.writer());
}
