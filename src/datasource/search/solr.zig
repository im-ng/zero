const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// Apache Solr search backend (HTTP API via `zul`). Uses the standard
/// `/solr/<collection>/update` (JSON add) and `/solr/<collection>/select`
/// (query) endpoints.
pub const Solr = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    base_url: []const u8,
    default_collection: []const u8,
    basic_auth: ?[]const u8,
    // Last upstream failure, surfaced thread-safely via `lastError()`. The HTTP
    // status and an `ErrorKind` are stored atomically (no shared heap buffer),
    // so concurrent requests and the health probe read them without a lock or a
    // use-after-free. Both reset at the start of each call.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        default_collection: []const u8,
        basic_auth: ?[]const u8 = null,
    }) !*Solr {
        const self = try allocator.create(Solr);

        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .base_url = try allocator.dupe(u8, opts.url),
            .default_collection = try allocator.dupe(u8, opts.default_collection),
            .basic_auth = if (opts.basic_auth) |a| try allocator.dupe(u8, a) else null,
        };

        return self;
    }

    pub fn index(self: *Solr, ctx: *root.Context, collection: []const u8, doc_json: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
        const coll_name = if (collection.len == 0) self.default_collection else collection;

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/solr/{s}/update?commit=true", .{ self.base_url, coll_name });

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;

        if (self.basic_auth) |a| {
            try req.header("authorization", a);
        }

        try req.header("content-type", "application/json");

        // Solr JSON add expects an array of docs wrapped in {"add": [...]}.
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"add\":[{s}]}}", .{doc_json});
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.SolrIndexFailed;
        }
    }

    pub fn query(self: *Solr, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
        const coll_name = if (collection.len == 0) self.default_collection else collection;

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/solr/{s}/select", .{ self.base_url, coll_name });

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;

        if (self.basic_auth) |a| {
            try req.header("authorization", a);
        }

        try req.header("accept", "application/json");
        try req.query("q", q);
        try req.query("wt", "json");

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.SolrQueryFailed;
        }

        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();

        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    pub fn get(self: *Solr, ctx: *root.Context, collection: []const u8, id: []const u8) !?[]const u8 {
        const hits = try self.query(ctx, collection, try std.fmt.allocPrint(ctx.allocator, "id:{s}", .{id}));
        defer ctx.allocator.free(hits);

        // A 0-result query returns valid JSON; surface it as `null` only on empty
        // response. Callers inspect the JSON for actual hits.
        if (hits.len == 0) {
            return null;
        }

        return try ctx.allocator.dupe(u8, hits);
    }

    pub fn delete(self: *Solr, ctx: *root.Context, collection: []const u8, id: []const u8) !void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
        const coll_name = if (collection.len == 0) self.default_collection else collection;

        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/solr/{s}/update?commit=true", .{ self.base_url, coll_name });

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;

        if (self.basic_auth) |a| {
            try req.header("authorization", a);
        }

        try req.header("content-type", "application/json");
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"delete\":[\"{s}\"]}}", .{id});
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.last_status.store(res.status, .monotonic);
            self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(res.status)), .monotonic);
            return error.SolrDeleteFailed;
        }
    }

    /// Thread-safe last-failure accessor. Returns `null` when the most recent
    /// attempt succeeded (or none has been made). `code` names the `ErrorKind`
    /// and `status` is the last HTTP status (0 for non-HTTP). The returned
    /// struct is a copy with no shared heap buffer, so it is safe to read.
    pub fn lastError(self: *Solr) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    /// Free the handle and its allocated strings.
    pub fn deinit(self: *Solr, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.base_url);
        allocator.free(self.default_collection);
        if (self.basic_auth) |a| {
            allocator.free(a);
        }
        allocator.destroy(self);
    }
};
