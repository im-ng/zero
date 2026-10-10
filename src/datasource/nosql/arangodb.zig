const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;
const base64 = std.base64;

/// ArangoDB multi-model (document) backend over its HTTP API via `zul`.
/// Holds a persistent `zul.http.Client`, the base URL, the target database, and
/// an optional Basic-auth header. All four `NoSQL` operations run AQL through
/// the `/_api/cursor` endpoint (INSERT/REMOVE/RETURN), which keeps the
/// statement-based `NoSQL` contract uniform across backends.
pub const ArangoDB = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    base_url: []const u8,
    db: []const u8,
    auth_header: ?[]const u8,

    // Last upstream failure, surfaced thread-safely via `lastError()`. Mirrors
    // the other datasource clients: HTTP status + `ErrorKind` stored atomically
    // (no shared heap buffer) so the health probe reads them without a lock.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        db: []const u8,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
    }) !*ArangoDB {
        var auth: ?[]const u8 = null;
        if (opts.user != null and opts.password != null) {
            const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ opts.user.?, opts.password.? });
            defer allocator.free(raw);
            const b64_len = base64.standard.Encoder.calcSize(raw.len);
            const b64 = try allocator.alloc(u8, b64_len);
            const encoded = base64.standard.Encoder.encode(b64, raw);
            auth = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
        }
        const self = try allocator.create(ArangoDB);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .base_url = try allocator.dupe(u8, opts.url),
            .db = try allocator.dupe(u8, opts.db),
            .auth_header = auth,
        };
        return self;
    }

    fn applyAuth(self: *ArangoDB, req: anytype) !void {
        if (self.auth_header) |h| {
            try req.header("authorization", h);
        }
    }

    fn cursorUrl(self: *ArangoDB, ctx: *root.Context) ![]const u8 {
        return try std.fmt.allocPrint(ctx.allocator, "{s}/_db/{s}/_api/cursor", .{ self.base_url, self.db });
    }

    /// Run an AQL statement (typically an INSERT/REMOVE) through `/_api/cursor`.
    pub fn put(self: *ArangoDB, ctx: *root.Context, statement: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try self.cursorUrl(ctx);
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try self.applyAuth(&req);
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .query = statement }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.ArangoDBPutFailed;
        }
    }

    /// Run a read AQL statement (a RETURN/COLLECT) through `/_api/cursor` and
    /// return the response body, owned by `ctx.allocator`. Returns `null` when
    /// the server answers 404 or with an empty body. Caller frees.
    pub fn get(self: *ArangoDB, ctx: *root.Context, statement: []const u8) !?[]const u8 {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try self.cursorUrl(ctx);
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try req.header("accept", "application/json");
        try self.applyAuth(&req);
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .query = statement }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status == 404) {
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return null;
        }
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.ArangoDBGetFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        if (sb.pos == 0) return null;
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Run an AQL REMOVE statement through `/_api/cursor`.
    pub fn delete(self: *ArangoDB, ctx: *root.Context, statement: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try self.cursorUrl(ctx);
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try self.applyAuth(&req);
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .query = statement }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.ArangoDBDeleteFailed;
        }
    }

    /// Run an arbitrary AQL statement through `/_api/cursor` and return the
    /// response body (the `result` array), owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *ArangoDB, ctx: *root.Context, statement: []const u8) ![]const u8 {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);

        const url = try self.cursorUrl(ctx);
        defer ctx.allocator.free(url);

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try req.header("accept", "application/json");
        try self.applyAuth(&req);
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .query = statement }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.ArangoDBQueryFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Thread-safe last-failure accessor. Returns `null` on recent success.
    pub fn lastError(self: *ArangoDB) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    /// Free the handle and its allocated strings.
    pub fn deinit(self: *ArangoDB, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.base_url);
        allocator.free(self.db);
        if (self.auth_header) |h| {
            allocator.free(h);
        }
        allocator.destroy(self);
    }
};
