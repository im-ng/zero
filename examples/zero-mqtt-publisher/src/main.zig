const std = @import("std");
const zero = @import("zero");

const Allocator = std.mem.Allocator;
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

    try app.addCronJob("* * * * * *", "publisher-1", publishTask1);

    try app.addCronJob("*/10 * * * * *", "publisher-2", publishTask2);

    try app.run();
}

fn publishTask1(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    const id = try ctx.MQ.Publish("zero", "publisher 1 says hello!");

    if (id) |_id| {
        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "Message {d} published", .{_id});
        // defer ctx.allocator.free(buffer);

        ctx.info(timestamp);
    }
}

fn publishTask2(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    const id = try ctx.MQ.Publish("zero", "publisher 2 says hi!");

    if (id) |_id| {
        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "Message {d} published", .{_id});

        ctx.info(timestamp);
    }
}
