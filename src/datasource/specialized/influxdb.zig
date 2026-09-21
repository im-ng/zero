const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// InfluxDB v2 time-series backend (HTTP API via `zul`). Holds a persistent
/// `zul.http.Client` and the org/bucket/token needed for the write & query APIs.
pub const InfluxDB = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    base_url: []const u8,
    org: []const u8,
    bucket: []const u8,
    token: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        org: []const u8,
        bucket: []const u8,
        token: ?[]const u8 = null,
    }) !*InfluxDB {
        const self = try allocator.create(InfluxDB);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .base_url = try allocator.dupe(u8, opts.url),
            .org = try allocator.dupe(u8, opts.org),
            .bucket = try allocator.dupe(u8, opts.bucket),
            .token = if (opts.token) |t| try allocator.dupe(u8, t) else null,
        };
        return self;
    }

    /// Write one line-protocol point: `measurement,tag=val field=val [ts]`.
    pub fn write(self: *InfluxDB, ctx: *root.Context, measurement: []const u8, tags: []const u8, fields: []const u8, ts: ?i64) !void {
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/v2/write", .{self.base_url});
        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.query("org", self.org);
        try req.query("bucket", self.bucket);
        if (self.token) |t| try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Token {s}", .{t}));
        try req.header("content-type", "text/plain");

        const ts_str = if (ts) |v| try std.fmt.allocPrint(ctx.allocator, " {d}", .{v}) else "";
        const body = try std.fmt.allocPrint(ctx.allocator, "{s}{s} {s}{s}", .{ measurement, tags, fields, ts_str });
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            std.log.warn("influxdb write failed: status={d} body={s}", .{ res.status, sb.buf[0..sb.pos] });
            return error.InfluxDBWriteFailed;
        }
    }

    /// Run a Flux query against `/api/v2/query` and return the CSV body, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn query(self: *InfluxDB, ctx: *root.Context, q: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/v2/query", .{self.base_url});
        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.query("org", self.org);
        if (self.token) |t| try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Token {s}", .{t}));
        try req.header("accept", "application/csv");
        try req.header("content-type", "application/vnd.flux");
        req.body(q);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            std.log.warn("influxdb query failed: status={d} body={s}", .{ res.status, sb.buf[0..sb.pos] });
            return error.InfluxDBQueryFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        return try ctx.allocator.dupe(u8, sb.buf[0..sb.pos]);
    }

    pub fn deinit(self: *InfluxDB, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.base_url);
        allocator.free(self.org);
        allocator.free(self.bucket);
        if (self.token) |t| allocator.free(t);
        allocator.destroy(self);
    }
};
