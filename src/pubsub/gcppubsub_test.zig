const std = @import("std");
const root = @import("../zero.zig");
const fakeserver = @import("../datasource/fakeserver.zig");

test "GCP Pub/Sub publish posts to topic:publish (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const gcp = try root.gcpPubSub.init(alloc, .{
        .project = "my-project",
        .endpoint = endpoint,
        .access_token_override = "tok",
    });
    defer gcp.deinit();

    try gcp.publish("my-topic", "hello-gcp");
}

test "GCP Pub/Sub init requires project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const err = root.gcpPubSub.init(alloc, .{ .project = "" });
    try std.testing.expectError(error.GcpProjectRequired, err);
}
