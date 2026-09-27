const std = @import("std");
const root = @import("../../zero.zig");
const fakeserver = @import("../fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "Solr index posts add doc and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"responseHeader\":{\"status\":0}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.index(&ctx, "docs", "{\"id\":\"1\",\"title\":\"hi\"}");
}

test "Solr index with basic_auth sends authorization header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs", .basic_auth = "Basic abc" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.index(&ctx, "docs", "{\"id\":\"2\"}");
}

test "Solr query returns JSON body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"response\":{\"numFound\":1}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.query(&ctx, "docs", "title:hi");
    defer ctx.allocator.free(got);
    try std.testing.expectEqualStrings("{\"response\":{\"numFound\":1}}", got);
}

test "Solr get returns null on empty response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.get(&ctx, "docs", "missing");
    try std.testing.expect(got == null);
}

test "Solr get returns body on hit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"response\":{\"docs\":[{\"id\":\"1\"}]}}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    const got = try s.get(&ctx, "docs", "1");
    defer if (got) |g| ctx.allocator.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("{\"response\":{\"docs\":[{\"id\":\"1\"}]}}", got.?);
}

test "Solr delete posts delete id and accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try s.delete(&ctx, "docs", "1");
}

test "Solr index non-2xx returns SolrIndexFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "boom" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.SolrIndexFailed, s.index(&ctx, "docs", "{\"id\":\"1\"}"));
}

test "Solr query non-2xx returns SolrQueryFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 400, .body = "bad" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.SolrQueryFailed, s.query(&ctx, "docs", "x"));
}

test "Solr delete non-2xx returns SolrDeleteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 503, .body = "down" });
    defer fs.stop();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const s = try root.Solr.create(alloc, .{ .url = url, .default_collection = "docs" });
    defer s.deinit(alloc);
    var ctx = ctxWith(alloc);

    try std.testing.expectError(error.SolrDeleteFailed, s.delete(&ctx, "docs", "1"));
}
