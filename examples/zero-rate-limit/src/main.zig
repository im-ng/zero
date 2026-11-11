const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    // The rate limiter is middleware wired automatically by the HTTP server. There
    // is nothing to register in code: set RATE_LIMIT_* env keys and the limiter
    // guards every route. This app exists so you can drive it with curl and watch
    // the 200 -> 429 -> Retry-After behavior change as you edit config.
    //
    // Memory store (default), limit 3 per 10s window:
    //   RATE_LIMIT_ENABLE=true
    //   RATE_LIMIT_MAX=3
    //   RATE_LIMIT_WINDOW=10
    // Distributed store over Redis (shared across app instances):
    //   RATE_LIMIT_STORE=redis
    //   REDIS_HOST=localhost REDIS_PORT=6379
    // Key by a client identifier header instead of connection IP:
    //   RATE_LIMIT_KEY=header:X-Client-Id
    // Behind a reverse proxy, trust it for header keys:
    //   RATE_LIMIT_TRUSTED_PROXIES=10.0.0.0/8

    try app.get("/", indexHandler);
    try app.get("/heavy", heavyHandler);

    try app.run();
}

fn indexHandler(ctx: *Context) !void {
    try ctx.json(.{ .ok = true, .hint = "hit /heavy a few times under the limit to see 429 + Retry-After" });
}

fn heavyHandler(ctx: *Context) !void {
    try ctx.json(.{ .ok = true, .route = "/heavy" });
}
