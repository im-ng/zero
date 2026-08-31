const std = @import("std");
const zero = @import("zero");

const Allocator = std.mem.Allocator;
const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

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
    try ctx.PubSub.Publish("zero", "publisher 1 says hello! via NATS");

    ctx.info(timestamp);
}

fn publishTask2(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    try ctx.PubSub.Publish("zero", "publisher 2 says hi! via NATS");

    ctx.info(timestamp);
}
