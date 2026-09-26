const std = @import("std");
const root = @import("../../zero.zig");
const service = root.circuit_breaker;
const utils = root.utils;

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
    /// Database name (the v3 `db` target for writes and queries).
    bucket: []const u8,
    token: ?[]const u8 = null,
};

/// Unified, type-erased time-series interface.
///
/// Usage (mirrors `ctx.SQL`):
///   try ctx.Timeseries.write(ctx, "cpu,host=server1 usage=42.1");
///   const csv = try ctx.Timeseries.query(ctx, "SELECT * FROM cpu");
pub const Timeseries = struct {
    ptr: *anyopaque,
    backend: Backend,
    /// Optional circuit breaker guarding all backend calls. When `null`, calls
    /// pass straight through (no trip/fail-fast).
    breaker: ?service.CircuitBreaker = null,
    metricz: ?*root.metricz = null,

    /// Build an interface handle from a concrete backend pointer.
    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker, metricz: ?*root.metricz) Timeseries {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
            .metricz = metricz,
        };
    }

    fn backendName(b: Backend) []const u8 {
        return switch (b) {
            .influxdb => "influxdb",
            .mock => "mock",
        };
    }

    fn dsError(self: *Timeseries, op: []const u8) void {
        var status: u16 = 0;
        if (self.lastError()) |d| status = d.status;
        if (self.metricz) |mz| {
            mz.datasourceError(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = status }) catch {};
        }
    }

    fn dsOk(self: *Timeseries, op: []const u8, start: std.Io.Timestamp) void {
        if (self.metricz) |mz| {
            mz.datasourceResponse(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = 200 }, utils.elapsedMs(start)) catch {};
        }
    }

    /// Construct a fully wired handle from backend + options.
    pub fn build(container: *root.container, backend: Backend, opts: Options) !*Timeseries {
        const impl: *anyopaque = switch (backend) {
            .influxdb => blk: {
                const c = try root.InfluxDB.create(container.allocator, .{
                    .url = opts.url,
                    .bucket = opts.bucket,
                    .token = opts.token.?,
                });
                break :blk @as(*anyopaque, c);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{};
                break :blk @as(*anyopaque, mb);
            },
        };
        const handle = try container.allocator.create(Timeseries);
        handle.* = Timeseries.init(impl, backend, null, container.metricz);
        return handle;
    }

    /// Write a single line-protocol point. `statement` is the full line protocol
    /// line (`measurement,tag=val field=val [ts]`). Mirrors `query`.
    pub fn write(self: *Timeseries, ctx: *root.Context, statement: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).write(ctx, statement),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).write(ctx, statement),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("write");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("write", start);
        return r;
    }

    /// Run a query (SQL or InfluxQL for InfluxDB v3) and return the raw response
    /// body, owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *Timeseries, ctx: *root.Context, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("query");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("query", start);
        return r;
    }

    /// Ensure the backing database (v3 "bucket") exists. No-op for the mock
    /// backend; safe to call at startup before any writes.
    pub fn createDatabase(self: *Timeseries, ctx: *root.Context, name: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).createDatabase(ctx, name),
            .mock => {},
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("createDatabase");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("createDatabase", start);
        return r;
    }

    /// Right after catching an `InfluxDB*Failed` error, report the last
    /// failure class to the health probe. `lastError()` returns a *copy* of
    /// the status/`ErrorKind` (no shared heap buffer), so it is thread-safe to
    /// call from the probe while requests run concurrently.
    pub fn lastError(self: *Timeseries) ?root.Error.DataSourceError {
        return switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).lastError(),
            .mock => null,
        };
    }

    /// Free the backend impl (and its client/pooled connections) and the
    /// type-erased handle. Must be called during teardown after any request
    /// threads have stopped touching `ctx.Timeseries`.
    pub fn deinit(self: *Timeseries, allocator: std.mem.Allocator) void {
        switch (self.backend) {
            .influxdb => @as(*root.InfluxDB, @ptrCast(@alignCast(self.ptr))).deinit(allocator),
            .mock => allocator.destroy(@as(*MockBackend, @ptrCast(@alignCast(self.ptr)))),
        }
        allocator.destroy(self);
    }
};

/// Native-free backend used by tests to verify `Timeseries` dispatch without a
/// running InfluxDB.
pub const MockBackend = struct {
    writes: u32 = 0,
    queries: u32 = 0,

    pub fn write(self: *MockBackend, _: *root.Context, _: []const u8) !void {
        self.writes += 1;
    }

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }
};

// ===================== Tests =====================

// test "Timeseries dispatches through the type-erased handle" {
//     var mock: MockBackend = .{};
//     var ts = Timeseries.init(&mock, .mock, null, null);
//     var ctx_storage: root.Context = undefined;
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     ctx_storage.allocator = arena.allocator();

//     try ts.write(&ctx_storage, "cpu,host=server1 usage=42.1");
//     try std.testing.expectEqual(@as(u32, 1), mock.writes);

//     _ = try ts.query(&ctx_storage, "SELECT * FROM cpu");
//     try std.testing.expectEqual(@as(u32, 1), mock.queries);
// }
