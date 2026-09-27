const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

// The v3 write endpoint is `/api/v3/write_lp?db=<bucket>` (not the
// v2-compatible `/api/v2/write`); the body is the raw line protocol.
test "InfluxDB write posts line protocol and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 204, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try db.write(&ctx, "cpu,host=a usage=1.0");
}

test "InfluxDB write with token sends authorization header and accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 204, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try db.write(&ctx, "cpu usage=9.5 1700000000000000000");
}

// The v3 query endpoint is `/api/v3/query_sql`; the database is pinned via the
// JSON `db` field so the caller need not qualify it in the statement.
test "InfluxDB query returns CSV body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .content_type = "text/csv", .body = "a,b\n1,2\n" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    const csv = try db.query(&ctx, "from(bucket:\"b\") |> range(start:-1h)");
    defer ctx.allocator.free(csv);
    try std.testing.expectEqualStrings("a,b\n1,2\n", csv);
}

test "InfluxDB write non-2xx returns InfluxDBWriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "boom" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.InfluxDBWriteFailed, db.write(&ctx, "cpu usage=1.0"));
}

test "InfluxDB query non-2xx returns InfluxDBQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 400, .body = "bad query" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.InfluxDBQueryFailed, db.query(&ctx, "bad"));
}

// `createDatabase` hits `/api/v3/configure/database` (the v3 management
// endpoint, not SQL) and treats any non-2xx as `InfluxDBQueryFailed`.
test "InfluxDB createDatabase accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"msg\":\"ok\"}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try db.createDatabase(&ctx, "demo");
}

test "InfluxDB createDatabase non-2xx returns InfluxDBQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "to str error" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.InfluxDB.create(alloc, .{ .url = url, .bucket = "b", .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.InfluxDBQueryFailed, db.createDatabase(&ctx, "demo"));
}
