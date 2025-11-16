const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const pubSubTopic = "zero";

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );
    defer arena_instance.deinit();

    const allocator = arena_instance.allocator();

    const app: *App = try App.new(allocator);

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
        m = customMessage{};
        m.msg = message.payload.?;
        m.topic = message.topic;

        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 1024);
        buffer = try std.fmt.bufPrint(buffer, "Received on [{s}] {s}", .{ m.topic, m.msg });
        defer ctx.allocator.free(buffer);

        ctx.info(timestamp);
        ctx.info(buffer);
    }
}
