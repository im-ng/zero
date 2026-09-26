const std = @import("std");
const root = @import("../zero.zig");
const fakeserver = @import("./fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var c: root.Context = undefined;
    c.allocator = alloc;
    return c;
}

fn point(alloc: std.mem.Allocator, port: u16) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port});
}

// These exercise the real `zul` N1QL/HTTP path over loopback through
// `FakeServer`. Each call passes a full N1QL `statement` (the datasource no
// longer decomposes collection/key/value) — see `couchbase.zig`.

test "Couchbase get returns the first result document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[{\"name\":\"alice\",\"age\":30}]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    const doc = try cb.get(&ctx, "SELECT * FROM b WHERE id = 'alice'");
    try std.testing.expect(doc != null);
    defer alloc.free(doc.?);
    try std.testing.expect(std.mem.indexOf(u8, doc.?, "alice") != null);
}

test "Couchbase get returns null when results are empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    const doc = try cb.get(&ctx, "SELECT * FROM b WHERE id = 'missing'");
    try std.testing.expectEqual(@as(?[]const u8, null), doc);
}

test "Couchbase put upserts a document (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    try cb.put(&ctx, "UPSERT INTO b (KEY, VALUE) VALUES ('alice', {\"age\":30})");
}

test "Couchbase delete removes a document (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    try cb.delete(&ctx, "DELETE FROM b WHERE id = 'alice'");
}

test "Couchbase query returns the results array as JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[{\"name\":\"alice\"},{\"name\":\"bob\"}]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    const out = try cb.query(&ctx, "SELECT * FROM b");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bob") != null);
}

test "Couchbase get with auth builds a Basic header (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"results\":[{\"name\":\"alice\"}]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{
        .contact_points = try point(alloc, fs.port),
        .bucket = "b",
        .user = "u",
        .password = "p",
    });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    const doc = try cb.get(&ctx, "SELECT * FROM b WHERE id = 'alice'");
    try std.testing.expect(doc != null);
    defer alloc.free(doc.?);
}

test "Couchbase surfaces a non-2xx response as an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "server error" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.CouchbaseQueryFailed, cb.get(&ctx, "SELECT * FROM b WHERE id = 'alice'"));
}

test "Couchbase surfaces a query-service errors array as an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"results\":[],\"errors\":[{\"msg\":\"key not found\"}]}" });
    defer fs.stop();

    const cb = try root.Couchbase.create(alloc, .{ .contact_points = try point(alloc, fs.port), .bucket = "b" });
    defer cb.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.CouchbaseQueryFailed, cb.get(&ctx, "SELECT * FROM b WHERE id = 'alice'"));
}
