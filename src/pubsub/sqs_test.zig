const std = @import("std");
const root = @import("../zero.zig");
const fakeserver = @import("../datasource/fakeserver.zig");

test "SQS publish sends SendMessage (2xx)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fs = try fakeserver.FakeServer.start(.{ .status = 200, .body = "{}" });
    defer fs.stop();

    const queue_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{fs.port});
    const sqs = try root.sqs.init(alloc, .{
        .region = "us-east-1",
        .access_key = "AKIDEXAMPLE",
        .secret_key = "secret",
        .queue_url = queue_url,
    });
    defer sqs.deinit();

    try sqs.publish("topic", "hello-sqs");
}

test "SQS init requires queue url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const err = root.sqs.init(alloc, .{ .queue_url = "" });
    try std.testing.expectError(error.SqsQueueUrlRequired, err);
}
