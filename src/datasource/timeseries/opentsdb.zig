const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// OpenTSDB time-series backend (HTTP API via `zul`). Holds a persistent
/// `zul.http.Client`, the base URL, and an optional auth token. Writes post a
/// JSON data point (or array of points) to `/api/put`; queries POST a JSON
/// query object to `/api/query` and return the response body.
pub const OpenTSDB = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    base_url: []const u8,
    token: ?[]const u8,

    // Last upstream failure, surfaced thread-safely via `lastError()`. Mirrors
    // `influxdb.zig`: the HTTP status and an `ErrorKind` are stored atomically
    // (no shared heap buffer) so concurrent requests and the health probe read
    // them without a lock or a use-after-free. Both reset at the start of each call.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        token: ?[]const u8 = null,
    }) !*OpenTSDB {
        const self = try allocator.create(OpenTSDB);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .base_url = try allocator.dupe(u8, opts.url),
            .token = if (opts.token) |t| allocator.dupe(u8, t) catch null else null,
        };
        return self;
    }

    fn applyAuth(self: *OpenTSDB, req: anytype) !void {
        if (self.token) |t| {
            const h = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
            defer self.allocator.free(h);
            try req.header("authorization", h);
        }
    }

    /// Write one or more JSON data points. `statement` is the raw OpenTSDB
    /// `/api/put` payload (a single point object or an array of them). The
    /// server returns 204 (no body) or 200 with an errors array on success.
    pub fn write(self: *OpenTSDB, ctx: *root.Context, statement: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/put", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try self.applyAuth(&req);
        req.body(statement);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.OpenTSDBWriteFailed;
        }
    }

    /// Run a JSON query against `/api/query` and return the response body, owned
    /// by `ctx.allocator`. Caller frees.
    pub fn query(self: *OpenTSDB, ctx: *root.Context, q: []const u8) ![]const u8 {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/query", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try req.header("accept", "application/json");
        try self.applyAuth(&req);
        req.body(q);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.OpenTSDBQueryFailed;
        }

        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// OpenTSDB is schema-less (metrics are created on first write), so there is
    /// no database to provision. This is a no-op that just resets the last-error
    /// state and returns, keeping the `Timeseries` contract uniform.
    pub fn createDatabase(self: *OpenTSDB, ctx: *root.Context, _: []const u8) !void {
        _ = ctx;
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
    }

    /// Thread-safe last-failure accessor. Returns `null` when the most recent
    /// attempt succeeded (or none has been made).
    pub fn lastError(self: *OpenTSDB) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    /// Free the handle and its allocated strings.
    pub fn deinit(self: *OpenTSDB, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.base_url);
        if (self.token) |t| {
            allocator.free(t);
        }
        allocator.destroy(self);
    }
};
