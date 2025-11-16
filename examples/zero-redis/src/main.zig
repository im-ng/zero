const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const redis = zero.rediz;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const app: *App = try App.new(allocator);

    app.onStatup(prepareCache);

    try app.get("/redis", cacheResponse);

    try app.run();
}

fn prepareCache(ctx: *Context) !void {
    ctx.info("warming up the cache entries");

    _ = ctx.Cache.send(void, .{ "SET", "msg", "zero redis message" }) catch |err| {
        ctx.any(err);
    };

    // intentional delay to mimic cache preparation
    std.Thread.sleep(std.time.ns_per_s);

    ctx.info("cache prepared");
}

const Data = struct {
    msg: []const u8,
};

fn cacheResponse(ctx: *Context) !void {
    // const FixBuf = redis.types.FixBuf;
    const reply = try ctx.Cache.sendAlloc([]u8, ctx.allocator, .{ "GET", "msg" });
    defer ctx.allocator.free(reply);

    try ctx.json(reply);
}
