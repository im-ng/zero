const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    app.onStartup(prepareCache);

    try app.get("/redis", cacheResponse);

    try app.run();
}

fn prepareCache(ctx: *Context) !void {
    ctx.info("warming up the cache entries");

    if (ctx.KV) |kv| {
        kv.set(ctx, "msg", "zero redis message") catch |err| ctx.any(err);
    }

    // intentional delay to mimic cache preparation
    try std.Io.sleep(utils.io, .{ .nanoseconds = std.time.ns_per_s }, .awake);

    ctx.info("cache prepared");
}

const Data = struct {
    msg: []const u8,
};

fn cacheResponse(ctx: *Context) !void {
    const reply = try ctx.KV.?.get(ctx, "msg");
    defer if (reply) |r| ctx.allocator.free(r);

    try ctx.json(reply orelse "");
}
