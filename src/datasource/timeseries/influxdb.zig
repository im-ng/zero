const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// InfluxDB v3 time-series backend (HTTP API via `zul`). Holds a persistent
/// `zul.http.Client`, the database name (`bucket`), and the auth token.
/// Writes post line protocol to the database-selected write endpoint; queries
/// run SQL/InfluxQL through `/api/v3/query_sql`.
pub const InfluxDB = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    base_url: []const u8,
    bucket: []const u8,
    token: []const u8,

    // Last upstream failure, surfaced thread-safely via `lastError()`. The HTTP
    // status and an `ErrorKind` are stored atomically (no shared heap buffer),
    // so concurrent requests and the health probe read them without a lock or a
    // use-after-free. Both reset at the start of each call.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        bucket: []const u8,
        token: []const u8,
    }) !*InfluxDB {
        const self = try allocator.create(InfluxDB);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .base_url = try allocator.dupe(u8, opts.url),
            .bucket = try allocator.dupe(u8, opts.bucket),
            .token = try allocator.dupe(u8, opts.token),
        };

        return self;
    }

    /// Write one line-protocol point: `measurement,tag=val field=val [ts]`.
    /// The server's database is selected with the v3 `bucket` query param.
    /// Write a single line-protocol point. `statement` is the full line protocol
    /// line (`measurement,tag=val field=val [ts]`); the database is selected via
    /// the v3 `db` query param on the native `/api/v3/write_lp` .
    /// Mirrors `query`, which also takes a raw statement (SQL/InfluxQL).
    pub fn write(self: *InfluxDB, ctx: *root.Context, statement: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/v3/write_lp", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;

        try req.header("content-type", "text/plain");
        try req.query("db", self.bucket);

        const auth = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{self.token});
        defer ctx.allocator.free(auth);

        try req.header("authorization", auth);
        req.body(statement);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);

            return error.InfluxDBWriteFailed;
        }
    }

    /// Run a SQL or InfluxQL statement against `/api/v3/query_sql` and return the
    /// CSV (or JSON) response body, owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *InfluxDB, ctx: *root.Context, q: []const u8) ![]const u8 {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/v3/query_sql", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;

        const auth = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{self.token});
        defer ctx.allocator.free(auth);
        try req.header("authorization", auth);

        try req.header("accept", "application/json");
        try req.header("content-type", "application/json");

        // `Stringify` escapes the statement, so a query containing quotes or
        // backslashes stays valid JSON. The database is pinned via `db` so the
        // caller need not qualify it in the statement.
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .db = self.bucket, .q = q }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.InfluxDBQueryFailed;
        }

        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();

        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Create the named database (the v3 "bucket") if it does not exist, so
    /// later writes/queries do not fail on a missing database. v3 exposes this
    /// through the management endpoint `/api/v3/configure/database` (not SQL).
    pub fn createDatabase(self: *InfluxDB, ctx: *root.Context, name: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/v3/configure/database", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;

        const auth = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{self.token});
        defer ctx.allocator.free(auth);
        try req.header("authorization", auth);

        try req.header("accept", "application/json");
        try req.header("content-type", "application/json");

        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .db = name }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.InfluxDBQueryFailed;
        }
    }

    /// Thread-safe last-failure accessor. Returns `null` when the most recent
    /// attempt succeeded (or none has been made). `code` names the `ErrorKind`
    /// and `status` is the last HTTP status (0 for non-HTTP). The returned
    /// struct is a copy with no shared heap buffer, so it is safe to read.
    pub fn lastError(self: *InfluxDB) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    /// Free the handle and its allocated strings.
    pub fn deinit(self: *InfluxDB, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.base_url);
        allocator.free(self.bucket);
        allocator.free(self.token);
        allocator.destroy(self);
    }
};
