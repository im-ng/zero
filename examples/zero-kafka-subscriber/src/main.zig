const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const topicName = "zero-topic";

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.environ_map);

    try app.addKafkaSubscription(topicName, subscribeTask);

    try app.run();
}

const customMessage = struct {
    msg: []const u8 = undefined,
    topic: []const u8 = undefined,
};

fn subscribeTask(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    //transform ctx.message to custom type in packet read itself
    if (ctx.message2) |message| {
        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 1024);
        buffer = try std.fmt.bufPrint(buffer, "Received on [{s}] {s}", .{ message.topic, message.payload.? });

        ctx.info(timestamp);
        ctx.info(buffer);
    }
}
