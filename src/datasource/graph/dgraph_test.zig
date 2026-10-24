const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "Dgraph query posts to /query and returns body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"data\":{\"me\":[{\"name\":\"Alice\"}]}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const d = try root.Dgraph.create(alloc, .{ .url = url });
    defer d.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try d.query(&ctx, "query { me { name } }");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"data\":{\"me\":[{\"name\":\"Alice\"}]}}", got);
}

test "Dgraph query with api_key sends X-Dgraph-AccessToken and accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"data\":{}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const d = try root.Dgraph.create(alloc, .{ .url = url, .api_key = "tok" });
    defer d.deinit(alloc);
    var ctx = ctxWith(alloc);

    _ = try d.query(&ctx, "{ me { name } }");
}

test "Dgraph mutate posts to /mutate and returns body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"data\":{\"code\":\"Success\"}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const d = try root.Dgraph.create(alloc, .{ .url = url });
    defer d.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try d.mutate(&ctx, "{\"set\":[{\"name\":\"Alice\"}]}");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"data\":{\"code\":\"Success\"}}", got);
}

test "Dgraph query non-2xx returns DgraphQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "err" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const d = try root.Dgraph.create(alloc, .{ .url = url });
    defer d.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.DgraphQueryFailed, d.query(&ctx, "query { me { name } }"));
}

test "Dgraph mutate non-2xx returns DgraphMutateFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 400, .body = "bad" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const d = try root.Dgraph.create(alloc, .{ .url = url });
    defer d.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.DgraphMutateFailed, d.mutate(&ctx, "{\"set\":[]}"));
}

test "Graph dispatches through the dgraph handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"data\":{}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    var dg = try root.Dgraph.create(alloc, .{ .url = url });
    defer dg.deinit(alloc);
    var s = root.Graph.init(dg, .dgraph, null, null);
    var ctx = ctxWith(alloc);

    const got = try s.query(&ctx, "{ me { name } }");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"data\":{}}", got);
}
