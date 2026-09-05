const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const pubSubTopic = "zero";

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.environ_map);

    try app.addSubscription(pubSubTopic, subscribeTask);

    // prefer only one topic for now
    // second one will not be captured
    // try app.addSubscription("second", subscribeTask);

    try app.run();
}

const customMessage = struct {
    msg: []const u8 = undefined,
    topic: []const u8 = undefined,
};

fn subscribeTask(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    var m: customMessage = undefined;

    //transform ctx.message to custom type in packet read itself
    if (ctx.message) |message| {
        const mq = message.mqtt;
        m = customMessage{};
        m.msg = mq.payload.?;
        m.topic = mq.topic;

        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 1024);
        buffer = try std.fmt.bufPrint(buffer, "Received on [{s}] {s}", .{ m.topic, m.msg });

        ctx.info(timestamp);
        ctx.info(buffer);
    }
}
