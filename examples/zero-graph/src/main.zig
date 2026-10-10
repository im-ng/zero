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

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);
    try app.post("/query", query);
    try app.post("/mutate", mutate);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ Dgraph (graph database) demo, via the unified ctx.Graph surface.
        \\ Routes:
        \\   POST /query   run a GraphQL/DQL query (request body = the query)
        \\   POST /mutate  run a mutation (request body = JSON/RDF mutation)
        \\
        \\ Set DGRAPH_URL (and optionally DGRAPH_API_KEY) in configs/.env.
    ;
}

pub fn query(ctx: *Context) !void {
    if (ctx.Graph == null) {
        notConfigured(ctx);
        return;
    }

    const q = ctx.request.?.body() orelse "";
    const res = ctx.Graph.?.query(ctx, q) catch |e| {
        if (graphUpstreamError(ctx, e)) return;
        return e;
    };
    defer ctx.allocator.free(res);

    ctx.response.content_type = .JSON;
    try ctx.response.writer().writeAll(res);
}

pub fn mutate(ctx: *Context) !void {
    if (ctx.Graph == null) {
        notConfigured(ctx);
        return;
    }

    const m = ctx.request.?.body() orelse "";
    const res = ctx.Graph.?.mutate(ctx, m) catch |e| {
        if (graphUpstreamError(ctx, e)) return;
        return e;
    };
    defer ctx.allocator.free(res);

    ctx.response.content_type = .JSON;
    try ctx.response.writer().writeAll(res);
}

/// Map a Dgraph upstream failure to an explicit error response. The datasource
/// no longer logs; the status + message live on `ctx.Graph.lastError()` and are
/// surfaced here. Returns `true` when handled (response already written).
fn graphUpstreamError(ctx: *Context, err: anyerror) bool {
    const is_dgraph = err == error.DgraphQueryFailed or
        err == error.DgraphMutateFailed;
    if (!is_dgraph) return false;
    const detail = ctx.Graph.?.lastError() orelse return false;
    ctx.response.setStatus(switch (detail.status) {
        401, 403 => .unauthorized,
        404 => .not_found,
        else => .bad_gateway,
    });
    ctx.response.json(.{ .err = "dgraph_upstream_failed", .status = detail.status, .message = detail.message }, .{}) catch {};
    return true;
}

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(
        .{
            .message = "DGRAPH_URL not configured",
        },
        .{},
    ) catch {};
}
