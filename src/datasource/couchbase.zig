const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// Couchbase document backend over N1QL/HTTP.
/// Talks the query service (`8093`) via the framework's
/// `zul` HTTP client with HTTP Basic auth — no `libcouchbase` C library to link.
/// Documents are projected onto a Couchbase bucket/collection; the document id
/// maps to `meta().id` and the JSON body is the document value.
pub const Couchbase = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    contact_point: []const u8,
    bucket: []const u8,
    user: ?[]const u8,
    password: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        bucket: []const u8,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
    }) !*Couchbase {
        // Take the first contact point (comma-separated list supported).
        var cp = std.mem.splitScalar(u8, opts.contact_points, ',');
        const first = cp.first();
        const self = try allocator.create(Couchbase);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .contact_point = try allocator.dupe(u8, first),
            .bucket = try allocator.dupe(u8, opts.bucket),
            .user = if (opts.user) |u| try allocator.dupe(u8, u) else null,
            .password = if (opts.password) |p| try allocator.dupe(u8, p) else null,
        };
        return self;
    }

    /// Run a N1QL `statement` and return the parsed response as a `std.json.Value`
    /// (owned by `ctx.allocator`). Surfaces query-service errors as
    /// `error.CouchbaseQueryFailed`.
    fn runN1ql(self: *Couchbase, ctx: *root.Context, statement: []const u8) !std.json.Value {
        const url = try std.fmt.allocPrint(ctx.allocator, "http://{s}/query", .{self.contact_point});
        var req = try self.client.allocRequest(ctx.allocator, url);
        defer {
            ctx.allocator.free(url);
            req.deinit();
        }
        req.method = .POST;
        try req.header("content-type", "application/json");
        if (self.user) |u| {
            const creds = try std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{ u, self.password orelse "" });
            defer ctx.allocator.free(creds);
            const enc = std.base64.standard.Encoder;
            const b64 = try ctx.allocator.alloc(u8, enc.calcSize(creds.len));
            const encoded = enc.encode(b64, creds);
            defer ctx.allocator.free(b64);
            try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Basic {s}", .{encoded}));
        }

        // Build the JSON request body, letting std.json escape the statement.
        var obj = std.json.ObjectMap.empty;
        try obj.put(ctx.allocator, "statement", std.json.Value{ .string = statement });
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = obj }, .{});
        defer ctx.allocator.free(body);
        req.body(body);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(ctx.allocator, .{});
            defer sb.deinit();
            std.log.warn("couchbase query failed: status={d} body={s}", .{ res.status, sb.buf[0..sb.pos] });
            return error.CouchbaseQueryFailed;
        }
        const sb = try res.allocBody(ctx.allocator, .{});
        defer sb.deinit();
        var parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, sb.buf[0..sb.pos], .{ .ignore_unknown_fields = true });
        if (parsed == .object) {
            if (parsed.object.get("errors")) |errs| {
                if (errs == .array and errs.array.items.len > 0) {
                    std.log.warn("couchbase query service error: {s}", .{sb.buf[0..sb.pos]});
                    return error.CouchbaseQueryFailed;
                }
            }
        }
        return parsed;
    }

    /// Extract the `results` array from a N1QL response (may be empty).
    fn results(self: *Couchbase, resp: std.json.Value) ![]std.json.Value {
        _ = self;
        if (resp == .object) {
            if (resp.object.get("results")) |r| {
                if (r == .array) return r.array.items;
            }
        }
        return &[0]std.json.Value{};
    }

    /// Serialize a `std.json.Value` into a caller-owned `[]const u8`.
    fn dump(self: *Couchbase, alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        _ = self;
        return try std.json.Stringify.valueAlloc(alloc, value, .{});
    }

    pub fn get(self: *Couchbase, ctx: *root.Context, collection: []const u8, key: []const u8) !?[]const u8 {
        const bucket = if (collection.len == 0) self.bucket else collection;
        const stmt = try std.fmt.allocPrint(ctx.allocator, "SELECT RAW b FROM `{s}` b WHERE meta(b).id = '{s}'", .{ bucket, key });
        defer ctx.allocator.free(stmt);
        const resp = try self.runN1ql(ctx, stmt);
        const rows = try self.results(resp);
        if (rows.len == 0) return null;
        return try self.dump(ctx.allocator, rows[0]);
    }

    /// Upsert a document. `value` must be a valid JSON string (the document body).
    pub fn put(self: *Couchbase, ctx: *root.Context, collection: []const u8, key: []const u8, value: []const u8) !void {
        const bucket = if (collection.len == 0) self.bucket else collection;
        const stmt = try std.fmt.allocPrint(ctx.allocator, "UPSERT INTO `{s}` (KEY, VALUE) VALUES ('{s}', {s})", .{ bucket, key, value });
        defer ctx.allocator.free(stmt);
        _ = try self.runN1ql(ctx, stmt);
    }

    pub fn delete(self: *Couchbase, ctx: *root.Context, collection: []const u8, key: []const u8) !void {
        const bucket = if (collection.len == 0) self.bucket else collection;
        const stmt = try std.fmt.allocPrint(ctx.allocator, "DELETE FROM `{s}` b WHERE meta(b).id = '{s}'", .{ bucket, key });
        defer ctx.allocator.free(stmt);
        _ = try self.runN1ql(ctx, stmt);
    }

    /// Run an arbitrary N1QL statement and return the `results` array as JSON,
    /// owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *Couchbase, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        _ = collection;
        const resp = try self.runN1ql(ctx, q);
        const rows = try self.results(resp);
        var arr = std.json.Array.init(ctx.allocator);
        for (rows) |r| try arr.append(r);
        return try self.dump(ctx.allocator, std.json.Value{ .array = arr });
    }

    /// Free the handle and its allocated strings.
    pub fn deinit(self: *Couchbase, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.contact_point);
        allocator.free(self.bucket);
        if (self.user) |u| allocator.free(u);
        if (self.password) |p| allocator.free(p);
        allocator.destroy(self);
    }
};

// ===================== Tests =====================

// test "Couchbase extracts results and serializes" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//     const cb = try Couchbase.create(alloc, .{ .contact_points = "localhost:8093", .bucket = "b" });
//     defer cb.deinit(alloc);

//     const resp = std.json.Value{
//         .object = blk: {
//             var o = std.json.ObjectMap.empty;
//             var arr = std.json.Array.init(alloc);
//             var doc = std.json.ObjectMap.empty;
//             try doc.put(alloc, "name", std.json.Value{ .string = "alice" });
//             try arr.append(std.json.Value{ .object = doc });
//             try o.put(alloc, "results", std.json.Value{ .array = arr });
//             break :blk o;
//         },
//     };

//     const rows = try cb.results(resp);
//     try std.testing.expectEqual(@as(usize, 1), rows.len);

//     const out = try cb.dump(alloc, rows[0]);
//     defer alloc.free(out);
//     try std.testing.expectEqualStrings("{\"name\":\"alice\"}", out);
// }

// test "Couchbase results is empty when absent or empty" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//     const cb = try Couchbase.create(alloc, .{ .contact_points = "localhost:8093", .bucket = "b" });
//     defer cb.deinit(alloc);

//     const absent = try cb.results(std.json.Value{ .object = std.json.ObjectMap.empty });
//     try std.testing.expectEqual(@as(usize, 0), absent.len);

//     const empty = try cb.results(std.json.Value{
//         .object = blk: {
//             var o = std.json.ObjectMap.empty;
//             try o.put(alloc, "results", std.json.Value{ .array = std.json.Array.init(alloc) });
//             break :blk o;
//         },
//     });
//     try std.testing.expectEqual(@as(usize, 0), empty.len);
// }

// test "Couchbase dump serializes scalars, arrays and nested objects" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//     const cb = try Couchbase.create(alloc, .{ .contact_points = "localhost:8093", .bucket = "b" });
//     defer cb.deinit(alloc);

//     const s = try cb.dump(alloc, std.json.Value{ .string = "x" });
//     defer alloc.free(s);
//     try std.testing.expectEqualStrings("\"x\"", s);

//     const n = try cb.dump(alloc, std.json.Value{ .integer = 42 });
//     defer alloc.free(n);
//     try std.testing.expectEqualStrings("42", n);

//     const arr = try cb.dump(alloc, std.json.Value{ .array = blk: {
//         var a = std.json.Array.init(alloc);
//         try a.append(std.json.Value{ .string = "a" });
//         try a.append(std.json.Value{ .string = "b" });
//         break :blk a;
//     } });
//     defer alloc.free(arr);
//     try std.testing.expectEqualStrings("[\"a\",\"b\"]", arr);
// }

// test "Couchbase create stores credentials and frees cleanly" {
//     const alloc = std.testing.allocator;
//     const cb = try Couchbase.create(alloc, .{
//         .contact_points = "cp1:8093,cp2:8093",
//         .bucket = "b",
//         .user = "u",
//         .password = "p",
//     });
//     cb.deinit(alloc);
// }
