const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// Dgraph graph-database REST client over `zul` (no external driver). Covers
/// the Dgraph HTTP API: `POST /query` (GraphQL / DQL) and `POST /mutate`
/// (JSON/RDF mutation). Sends the optional `X-Dgraph-AccessToken` header when
/// an API key is configured. Mirrors `datasource/search/meiliClient.zig`.
pub const Client = struct {
    allocator: std.mem.Allocator,
    http: zul.http.Client,
    base_url: []const u8,
    auth_header: ?[]const u8,

    // Last upstream failure, surfaced thread-safely via `lastError()`. HTTP
    // status + `ErrorKind` are stored atomically (no shared heap buffer), so
    // the health probe reads them without a lock or a use-after-free.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        api_key: ?[]const u8 = null,
    }) Client {
        return .{
            .allocator = allocator,
            .http = zul.http.Client.init(utils.io, allocator),
            .base_url = allocator.dupe(u8, opts.url) catch "",
            .auth_header = if (opts.api_key) |k| allocator.dupe(u8, k) catch null else null,
        };
    }

    /// Reset the last-failure state at the start of each call.
    fn resetLast(self: *Client) void {
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
    }

    /// Record a failure into the atomic last-error fields.
    fn setLast(self: *Client, status: u16) void {
        self.last_status.store(status, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.classifyHttpStatus(status)), .monotonic);
    }

    fn applyAuth(self: *Client, req: anytype) !void {
        if (self.auth_header) |h| {
            try req.header("X-Dgraph-AccessToken", h);
        }
    }

    /// Run a query (GraphQL or DQL) against `POST /query` and return the
    /// response body, owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *Client, ctx: *root.Context, q: []const u8) ![]const u8 {
        self.resetLast();
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/query", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/graphql");
        try req.header("accept", "application/json");
        try self.applyAuth(&req);
        req.body(q);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.DgraphQueryFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Run a mutation (JSON/RDF) against `POST /mutate` and return the response
    /// body, owned by `ctx.allocator`. Caller frees.
    pub fn mutate(self: *Client, ctx: *root.Context, m: []const u8) ![]const u8 {
        self.resetLast();
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/mutate", .{self.base_url});
        defer ctx.allocator.free(url);

        var req = try self.http.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/json");
        try req.header("accept", "application/json");
        try self.applyAuth(&req);
        req.body(m);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            self.setLast(res.status);
            return error.DgraphMutateFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Thread-safe last-failure accessor. Returns `null` on recent success.
    pub fn lastError(self: *Client) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    /// Free the client and its allocated strings.
    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.http.deinit();
        if (self.base_url.len > 0) {
            allocator.free(self.base_url);
        }
        if (self.auth_header) |h| {
            allocator.free(h);
        }
    }
};
