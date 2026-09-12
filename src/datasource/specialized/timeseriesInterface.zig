const std = @import("std");
const root = @import("../../zero.zig");
const service = root.circuit_breaker;

/// Time-series backends. Resolved at runtime from config so the same type-erased
/// `Timeseries` handle works for any configured backend without the caller knowing
/// which one is active. Add new backends (Prometheus, VictoriaMetrics, …) here and
/// a case in the `switch` as they are implemented.
pub const Backend = enum {
    influxdb,
    /// Test-only backend backed by `MockBackend`. Lets the `Timeseries` dispatch
    /// be exercised without a running InfluxDB.
    mock,
};

/// Connection options for a `Timeseries` backend.
pub const Options = struct {
    url: []const u8,
    org: []const u8,
    bucket: []const u8,
    token: ?[]const u8 = null,
};

/// Unified, type-erased time-series interface.
///
/// Usage (mirrors `ctx.SQL`):
///   try ctx.Timeseries.write(ctx, "cpu", "host=server1", "usage=42.1", null);
///   const csv = try ctx.Timeseries.query(ctx, "from(bucket:\"metrics\") |> range(start:-1h)");
pub const Timeseries = struct {
    ptr: *anyopaque,
    backend: Backend,
    /// Optional circuit breaker guarding all backend calls. When `null`, calls
    /// pass straight through (no trip/fail-fast).
    breaker: ?service.CircuitBreaker = null,

    /// Build an interface handle from a concrete backend pointer.
    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker) Timeseries {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
        };
    }

    /// Construct a fully wired handle from backend + options.
    pub fn build(container: *root.container, backend: Backend, opts: Options) !*Timeseries {
        const impl: *anyopaque = switch (backend) {
            .influxdb => blk: {
                const c = try root.InfluxDB.create(container.allocator, .{
                    .url = opts.url,
                    .org = opts.org,
                    .bucket = opts.bucket,
                    .token = opts.token,
                });
                break :blk @as(*anyopaque, c);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{ .last_measurement = "" };
                break :blk @as(*anyopaque, mb);
            },
        };
        const handle = try container.allocator.create(Timeseries);
        handle.* = Timeseries.init(impl, backend, null);
        return handle;
    }

    /// Write a single line-protocol point. `ts` is an optional nanosecond epoch;
    /// when `null` the server assigns the timestamp.
    pub fn write(self: *Timeseries, ctx: *root.Context, measurement: []const u8, tags: []const u8, fields: []const u8, ts: ?i64) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).write(ctx, measurement, tags, fields, ts),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).write(ctx, measurement, tags, fields, ts),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Run a query (Flux for InfluxDB v2) and return the raw response body, owned
    /// by `ctx.allocator`. Caller frees.
    pub fn query(self: *Timeseries, ctx: *root.Context, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }
};

/// Native-free backend used by tests to verify `Timeseries` dispatch without a
/// running InfluxDB.
pub const MockBackend = struct {
    writes: u32 = 0,
    queries: u32 = 0,
    last_measurement: []const u8,

    pub fn write(self: *MockBackend, _: *root.Context, measurement: []const u8, _: []const u8, _: []const u8, _: ?i64) !void {
        self.writes += 1;
        self.last_measurement = measurement;
    }

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }
};

test "Timeseries dispatches through the type-erased handle" {
    var mock: MockBackend = .{ .last_measurement = "" };
    var ts = Timeseries.init(&mock, .mock, null);
    var ctx_storage: root.Context = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ctx_storage.allocator = arena.allocator();

    try ts.write(&ctx_storage, "cpu", "host=server1", "usage=42.1", null);
    try std.testing.expectEqual(@as(u32, 1), mock.writes);
    try std.testing.expectEqualStrings("cpu", mock.last_measurement);

    _ = try ts.query(&ctx_storage, "from(bucket:\"m\") |> range(start:-1h)");
    try std.testing.expectEqual(@as(u32, 1), mock.queries);
}
