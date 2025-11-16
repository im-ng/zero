const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    // var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena_instance.deinit();
    // const allocator = arena_instance.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const app = try App.new(allocator);

    try app.addCronJob("* * * * * *", "task-1", task1);
    app.container.log.info("task 1 occurs every 5 seconds of minutes");

    try app.addCronJob("*/5 * * * * *", "task-2", task2);
    app.container.log.info("task 2 occurs between 30-40 second of every minute");

    try app.run();
}

fn task1(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    ctx.info(timestamp);
}

fn task2(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);
    ctx.info(timestamp);
}
