const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// Self-contained Meilisearch REST client over `zul` (no external driver).
///
/// Covers the subset the unified `Search` interface needs: index (upsert),
/// search, get, delete, plus index creation. Auth uses the
/// `Authorization: Bearer <api_key>` header. The last upstream failure is kept
/// in atomics so the health probe can read it without a lock.
///
/// This is the standalone client half of the Meilisearch backend, mirroring
/// `cassandra.zig` / `cassandraClient.zig`. `meili.zig` wraps it into the
/// `Search` interface.
pub const Client = struct {
    allocator: std.mem.Allocator,
    http: zul.http.Client,
    base_url: []const u8,
    default_index: []const u8,
    auth_header: ?[]const u8,
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub const Error = error{
        MeiliIndexFailed,
        MeiliQueryFailed,
        MeiliGetFailed,
        MeiliDeleteFailed,
    };

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        default_collection: []const u8,
        api_key: ?[]const u8 = null,
    }) Client {
        const auth_header = if (opts.api_key) |k|
            std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) catch null
        else
            null;

        return .{
            .allocator = allocator,
            .http = zul.http.Client.init(utils.io, allocator),
            .base_url = allocator.dupe(u8, opts.url) catch "",
            .default_index = allocator.dupe(u8, opts.default_collection) catch "",
            .auth_header = auth_header,
        };
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.http.deinit();
        allocator.free(self.base_url);
        allocator.free(self.default_index);
        if (self.auth_header) |h| {
            allocator.free(h);
        }
    }

    fn resetLast(self: *Client) void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
    }

    fn setLast(self: *Client, status: u16) void {
        self.last_status.store(status, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(status)), .monotonic);
    }

    fn applyAuth(self: *Client, req: anytype) !void {
        if (self.auth_header) |h| {
            try req.header("authorization", h);
        }
    }

    /// Create an index (best-effort). A 409/400 means it already exists, which
    /// is treated as success so callers can create idempotently.
    pub fn createIndex(self: *Client, ctx: *root.Context, uid: []const u8) !void {
        self.resetLast();
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/indexes", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try self.applyAuth(&req);
        try req.header("content-type", "application/json");

        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"uid\":\"{s}\",\"primaryKey\":\"id\"}}", .{uid});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status == 409 or res.status == 400) {
            return;
        }
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.MeiliIndexFailed;
        }
    }

    /// Index (upsert) a JSON document into `index`.
    pub fn index(self: *Client, ctx: *root.Context, collection: []const u8, doc_json: []const u8) !void {
        self.resetLast();
        const idx = if (collection.len == 0) self.default_index else collection;
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/indexes/{s}/documents", .{ self.base_url, idx });
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try self.applyAuth(&req);
        try req.header("content-type", "application/json");
        req.body(doc_json);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.MeiliIndexFailed;
        }
    }

    /// Search `index` for `q` and return the JSON response body, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn search(self: *Client, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        self.resetLast();
        const idx = if (collection.len == 0) self.default_index else collection;
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/indexes/{s}/search", .{ self.base_url, idx });
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try self.applyAuth(&req);
        try req.header("content-type", "application/json");
        try req.header("accept", "application/json");

        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"q\":\"{s}\"}}", .{q});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.MeiliQueryFailed;
        }

        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Fetch a document by id. Returns null on 404; errors on other failures.
    pub fn getDocument(self: *Client, ctx: *root.Context, collection: []const u8, id: []const u8) !?[]const u8 {
        self.resetLast();
        const idx = if (collection.len == 0) self.default_index else collection;
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/indexes/{s}/documents/{s}", .{ self.base_url, idx, id });
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try self.applyAuth(&req);
        try req.header("accept", "application/json");

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status == 404) {
            return null;
        }
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.MeiliGetFailed;
        }

        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Delete a document by id.
    pub fn deleteDocument(self: *Client, ctx: *root.Context, collection: []const u8, id: []const u8) !void {
        self.resetLast();
        const idx = if (collection.len == 0) self.default_index else collection;
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/indexes/{s}/documents/{s}", .{ self.base_url, idx, id });
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .DELETE;
        try self.applyAuth(&req);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.MeiliDeleteFailed;
        }
    }

    /// Thread-safe last-failure accessor. Returns null when the most recent
    /// attempt succeeded (or none has been made).
    pub fn lastError(self: *Client) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }
};
