const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "OpenTSDB write posts JSON and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 204, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.OpenTSDB.create(alloc, .{ .url = url });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try db.write(&ctx, "{\"metric\":\"cpu\",\"timestamp\":1700000000,\"value\":42.1,\"tags\":{\"host\":\"a\"}}");
}

test "OpenTSDB write with token sends authorization header and accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 204, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.OpenTSDB.create(alloc, .{ .url = url, .token = "secret" });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try db.write(&ctx, "[{\"metric\":\"cpu\",\"value\":1.0}]");
}

test "OpenTSDB query returns JSON body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"metric\":\"cpu\",\"dps\":{\"1\":2}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.OpenTSDB.create(alloc, .{ .url = url });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try db.query(&ctx, "{\"start\":1,\"queries\":[{\"metric\":\"cpu\"}]}");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"metric\":\"cpu\",\"dps\":{\"1\":2}}", got);
}

test "OpenTSDB write non-2xx returns OpenTSDBWriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 400, .body = "bad" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.OpenTSDB.create(alloc, .{ .url = url });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.OpenTSDBWriteFailed, db.write(&ctx, "{\"metric\":\"cpu\"}"));
}

test "OpenTSDB query non-2xx returns OpenTSDBQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "down" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const db = try root.OpenTSDB.create(alloc, .{ .url = url });
    defer db.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.OpenTSDBQueryFailed, db.query(&ctx, "{\"start\":1}"));
}

test "Timeseries dispatches through the opentsdb handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"metric\":\"cpu\"}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    var ot = try root.OpenTSDB.create(alloc, .{ .url = url });
    defer ot.deinit(alloc);
    var s = root.Timeseries.init(ot, .opentsdb, null, null);
    var ctx = ctxWith(alloc);

    const got = try s.query(&ctx, "{\"start\":1}");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"metric\":\"cpu\"}", got);
}
