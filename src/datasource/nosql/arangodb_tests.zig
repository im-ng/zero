const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "ArangoDB put runs AQL and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"result\":[]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    try a.put(&ctx, "INSERT INTO users VALUES {}");
}

test "ArangoDB get returns body on 200" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"result\":[{\"_key\":\"1\"}]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try a.get(&ctx, "RETURN DOCUMENT('users/1')");
    defer if (got) |g| ctx.allocator.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("{\"result\":[{\"_key\":\"1\"}]}", got.?);
}

test "ArangoDB get returns null on 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 404, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try a.get(&ctx, "RETURN DOCUMENT('users/x')");
    try std.testing.expect(got == null);
}

test "ArangoDB delete runs AQL and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"result\":[]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    try a.delete(&ctx, "REMOVE doc IN users");
}

test "ArangoDB query returns body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"result\":[1,2]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try a.query(&ctx, "FOR u IN users RETURN u");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"result\":[1,2]}", got);
}

test "ArangoDB put non-2xx returns ArangoDBPutFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "err" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const a = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer a.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.ArangoDBPutFailed, a.put(&ctx, "INSERT INTO users VALUES {}"));
}

test "NoSQL dispatches through the arangodb handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"result\":[1]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    var ar = try root.ArangoDB.create(alloc, .{ .url = url, .db = "mydb" });
    defer ar.deinit(alloc);
    var n = root.NoSQL.init(ar, .arangodb, null, null);
    var ctx = ctxWith(alloc);

    try n.put(&ctx, "INSERT INTO users VALUES {}");
    const got = try n.query(&ctx, "FOR u IN users RETURN u");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"result\":[1]}", got);
}
