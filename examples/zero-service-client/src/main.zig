const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;
const ClientError = zero.Error.ClientError;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub const publicKey = struct {
    kid: []const u8,
    kty: []const u8,
    use: []const u8,
    n: []const u8,
    e: []const u8,
    alg: []const u8,
};

pub const publicKeys = struct {
    keys: []publicKey,
};

pub fn main() !void {
    var arean = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arean.deinit();

    const allocator = arean.allocator();

    const app = try App.new(allocator);

    try app.addHttpService("auth-service", app.config.get("SERVICE_URL"));

    try app.get("/keys", serviceStatus);

    try app.run();
}

fn serviceStatus(ctx: *Context) !void {
    const service = ctx.getService("auth-service");

    if (service) |basicSvc| {
        const response = try basicSvc.Get(ctx, publicKeys, "/keys", null, null);
        try ctx.json(response);
    }
}
