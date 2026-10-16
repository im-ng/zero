const std = @import("std");
const root = @import("../zero.zig");
const fakeserver = @import("../datasource/fakeserver.zig");

fn ctxWith(alloc: std.mem.Allocator) root.Context {
    var ctx: root.Context = undefined;
    ctx.allocator = alloc;
    return ctx;
}

test "GCS create uploads object via media endpoint (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .access_token_override = "tok",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    try store.create(&ctx, "avatars/1.png", "png-bytes");
}

test "GCS get returns object body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "filedata" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .access_token_override = "tok",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    const got = (try store.get(&ctx, "avatars/1.png")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("filedata", got);
}

test "GCS get returns null on 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 404, .body = "" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .access_token_override = "tok",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    try std.testing.expectEqual(@as(?[]const u8, null), try store.get(&ctx, "missing"));
}

test "GCS delete accepts 2xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 204, .body = "" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .access_token_override = "tok",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    try store.delete(&ctx, "avatars/1.png");
}

test "GCS list parses items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{\"items\":[{\"name\":\"a/1\"},{\"name\":\"a/2\"}]}" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .access_token_override = "tok",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    const items = try store.list(&ctx, "a/");
    defer {
        for (items) |k| {
            alloc.free(k);
        }
        alloc.free(items);
    }
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a/1", items[0]);
    try std.testing.expectEqualStrings("a/2", items[1]);
}

test "GCS fetches bearer token via client-credentials grant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Token endpoint returns an OAuth2 token response.
    var token_fs = try fakeserver.FakeServer.start(.{
        .status = 200,
        .body = "{\"access_token\":\"FAKE_TOKEN\",\"expires_in\":3600}",
    });
    defer token_fs.stop();

    // Storage endpoint returns the object body for the authenticated GET.
    var storage_fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "secret" });
    defer storage_fs.stop();

    const token_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{token_fs.port});
    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{storage_fs.port});
    const store = try root.filestore.gcs.FileStoreGCS.init(alloc, .{
        .endpoint = endpoint,
        .bucket = "my-bucket",
        .token_url = token_url,
        .client_id = "cid",
        .client_secret = "csec",
    });
    defer store.deinit();
    var ctx = ctxWith(alloc);

    const got = (try store.get(&ctx, "k")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("secret", got);
}
