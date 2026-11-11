const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

fn panic(msg: []const u8, return_address: ?usize) noreturn {
    _ = msg;
    std.log.err("=== Stack Trace ==============", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = return_address });
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var app = try App.new(allocator, init.io, init.environ_map);

    // One outbound service. Override SERVICE_UPSTREAM_BASE_URL; the starter
    // points at a public API so /upstream works out of the box. The framework
    // attaches any SERVICE_UPSTREAM_* auth and guards the downstream with a
    // circuit breaker automatically.
    try app.addHttpService("upstream", "https://api.github.com", .{});

    try app.get("/", index);
    try app.get("/json", jsonRoute);
    try app.get("/sql", sqlRoute);
    try app.get("/upstream", upstreamRoute);

    // Health is served at /.well-known/health and metrics at /metrics by the
    // framework's built-in metriczServer — no extra wiring needed.
    try app.run();
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .TEXT;
    ctx.response.body = "zero-starter: ok";
}

fn jsonRoute(ctx: *Context) !void {
    try ctx.response.json(.{ .message = "hello from zero-starter" }, .{});
}

fn sqlRoute(ctx: *Context) !void {
    if (ctx.container.SQL == null and ctx.container.MySQL == null and
        ctx.container.SQLite == null and ctx.container.DuckDB == null and
        ctx.container.ClickHouse == null and ctx.container.DuckGres == null)
    {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .TEXT;
        ctx.response.body = "no SQL backend configured (set DB_DIALECT)";
        return;
    }
    // A backend-agnostic probe query (no table needed) to show the unified
    // ctx.SQL surface. Swap in your own schema query.
    const row = ctx.SQL.queryRow(
        ctx,
        struct { id: i64, name: []const u8 },
        "SELECT 1 AS id, 'zero' AS name",
        .{},
    ) catch {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .TEXT;
        ctx.response.body = "SQL configured but query failed";
        return;
    };
    if (row) |r| {
        defer ctx.allocator.free(r.name);
        try ctx.response.json(r, .{});
    } else {
        try ctx.response.json(.{ .id = @as(i64, 0), .name = "none" }, .{});
    }
}

fn upstreamRoute(ctx: *Context) !void {
    const svc = ctx.getService("upstream") orelse {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .TEXT;
        ctx.response.body = "upstream service not configured";
        return;
    };
    // Fire a real outbound call. The client parses into a struct (unknown fields
    // ignored), so an empty struct accepts any JSON payload.
    _ = try svc.get(ctx, struct {}, "/", null, null);
    try ctx.response.json(.{ .ok = true }, .{});
}
