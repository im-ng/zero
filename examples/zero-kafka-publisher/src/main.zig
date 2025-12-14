const std = @import("std");
const zero = @import("zero");

const Allocator = std.mem.Allocator;
const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;
const helper = @import("helper.zig");
const payload = helper.payload;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const pubSubTopic = "zero-topic";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

    try app.addCronJob("* * * * * *", "publisher-1", publishTask1);

    try app.run();
}

fn publishTask1(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);

    const msgId = "publisher-1";

    const p: payload = payload{
        .timestamp = timestamp,
        .message = "publisher message!",
    };

    const jp = try helper.transform(ctx, &p);
    ctx.info(jp);

    const topic = try ctx.KF.getTopicHandler(ctx, pubSubTopic);

    ctx.KF.Publish(ctx, topic, msgId, jp) catch |err| {
        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "Message published failed {}", .{err});
        return;
    };

    ctx.info(timestamp);

    var buffer: []u8 = undefined;
    buffer = try ctx.allocator.alloc(u8, 100);
    buffer = try std.fmt.bufPrint(buffer, "Message published successfully", .{});
    ctx.info(buffer);
}
