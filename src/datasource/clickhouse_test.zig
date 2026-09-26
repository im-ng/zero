const std = @import("std");
const root = @import("../zero.zig");
const fakeserver = @import("./fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var c: root.Context = undefined;
    c.allocator = alloc;
    return c;
}

fn url(alloc: std.mem.Allocator, port: u16) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
}

test "ClickHouse queryRow fetches a row over HTTP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"data\":[{\"id\":1,\"name\":\"alice\"}]}" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    const row = try ch.queryRow(&ctx, Row, "SELECT id, name FROM events WHERE id = ?", .{@as(i64, 1)});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 1), row.?.id);
    try std.testing.expectEqualStrings("alice", row.?.name);
}

test "ClickHouse queryRows fetches all rows over HTTP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"data\":[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"name\":\"b\"}]}" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    const rows = try ch.queryRows(&ctx, Row, "SELECT id, name FROM events", .{});
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 2), rows[1].id);
}

test "ClickHouse selectSlice appends rows into a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"data\":[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"name\":\"b\"}]}" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    var list = std.array_list.Managed(Row).init(alloc);
    defer list.deinit();
    const n = try ch.selectSlice(&ctx, Row, &list, "SELECT id, name FROM events", .{});
    try std.testing.expectEqual(@as(i64, 2), n);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "ClickHouse execWithContext returns 0 (eventual consistency)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "Ok.\n" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const rc = try ch.execWithContext(&ctx, "INSERT INTO events VALUES (?)", .{@as(i64, 1)});
    try std.testing.expectEqual(@as(i64, 0), rc);
}

test "ClickHouse queryRowContext and queryRowsContext alias the row APIs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"data\":[{\"id\":9,\"name\":\"z\"}]}" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    const row = try ch.queryRowContext(&ctx, Row, "SELECT id, name FROM events", .{});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 9), row.?.id);

    const rows = try ch.queryRowsContext(&ctx, Row, "SELECT id, name FROM events", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
}

test "ClickHouse surfaces a non-2xx response as an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 500, .body = "server error" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    try std.testing.expectError(error.ClickHouseQueryFailed, ch.queryRow(&ctx, Row, "SELECT 1", .{}));
}

test "ClickHouse runRaw returns the raw body of a successful query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "1\n2\n3\n" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);

    const body = try ch.runRaw(alloc, "SELECT 1");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("1\n2\n3\n", body);
}

test "ClickHouse queryRow returns null when the result set is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .body = "{\"data\":[]}" });
    defer fs.stop();

    const ch = try root.ClickHouse.create(alloc, .{ .url = try url(alloc, fs.port) });
    defer ch.deinit(alloc);
    var ctx = ctxWith(alloc);

    const Row = struct { id: i64, name: []const u8 };
    const row = try ch.queryRow(&ctx, Row, "SELECT id, name FROM events WHERE id = ?", .{@as(i64, 999)});
    try std.testing.expect(row == null);
}
