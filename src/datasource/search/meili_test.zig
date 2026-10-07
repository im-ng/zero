const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "Meili index posts documents and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"taskUid\":1}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.index(&ctx, "docs", "{\"id\":\"1\",\"title\":\"hi\"}");
}

test "Meili index with api_key does not error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs", .api_key = "testkey" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.index(&ctx, "docs", "{\"id\":\"2\"}");
}

test "Meili query returns JSON body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"hits\":[{\"id\":\"1\"}]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.query(&ctx, "docs", "title:hi");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"hits\":[{\"id\":\"1\"}]}", got);
}

test "Meili get returns null on 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 404, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.get(&ctx, "docs", "missing");
    try std.testing.expect(got == null);
}

test "Meili get returns body on hit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"id\":\"1\"}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.get(&ctx, "docs", "1");
    defer if (got) |g| ctx.allocator.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("{\"id\":\"1\"}", got.?);
}

test "Meili delete accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.delete(&ctx, "docs", "1");
}

test "Meili index non-2xx returns MeiliIndexFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "boom" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.MeiliIndexFailed, s.index(&ctx, "docs", "{\"id\":\"1\"}"));
}

test "Meili query non-2xx returns MeiliQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 400, .body = "bad" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.MeiliQueryFailed, s.query(&ctx, "docs", "x"));
}

test "Meili delete non-2xx returns MeiliDeleteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 503, .body = "down" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.MeiliDeleteFailed, s.delete(&ctx, "docs", "1"));
}

test "Search dispatches through the meilisearch handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"hits\":[]}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    var meili = try root.Meili.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer meili.deinit(alloc);
    var s = root.Search.init(meili, .meilisearch, null, null);
    var ctx = ctxWith(alloc);

    try s.index(&ctx, "docs", "{\"id\":\"1\"}");
    const got = try s.query(&ctx, "docs", "title:shoe");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"hits\":[]}", got);
}
