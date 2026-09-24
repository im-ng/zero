const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const COLLECTION = "docs";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);
    try app.post("/docs", indexDoc);
    try app.get("/docs/:id", getDoc);
    try app.delete("/docs/:id", deleteDoc);
    try app.get("/search", search);
    try app.post("/search", search);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ Solr (search / persistence) demo.
        \\ Routes (collection = "docs"):
        \\   POST   /docs          index a JSON document (body must include "id")
        \\   GET    /docs/:id      fetch a document by id
        \\   DELETE /docs/:id      delete a document by id
        \\   GET    /search?q=<q>  search the collection
        \\   POST   /search        search the collection (request body = query)
        \\
        \\ Set SOLR_URL / SOLR_DEFAULT_COLLECTION in configs/.env.
    ;
}

pub fn indexDoc(ctx: *Context) !void {
    if (ctx.Search == null) {
        notConfigured(ctx);
        return;
    }

    const doc = ctx.request.body() orelse "";
    ctx.Search.?.index(ctx, COLLECTION, doc) catch |e| {
        if (searchUpstreamError(ctx, e)) return;
        return e;
    };

    try ctx.response.json(.{ .status = "indexed" }, .{});
}

pub fn getDoc(ctx: *Context) !void {
    if (ctx.Search == null) {
        notConfigured(ctx);
        return;
    }

    const id = ctx.request.params.get("id") orelse {
        badRequest(ctx, "missing :id");
        return;
    };
    const doc = ctx.Search.?.get(ctx, COLLECTION, id) catch |e| {
        if (searchUpstreamError(ctx, e)) return;
        return e;
    };

    if (doc) |d| {
        defer ctx.allocator.free(d);

        ctx.response.content_type = .JSON;
        try ctx.response.writer().writeAll(d);
    } else {
        ctx.response.setStatus(.not_found);
        try ctx.response.json(.{ .message = "not found", .id = id }, .{});
    }
}

pub fn deleteDoc(ctx: *Context) !void {
    if (ctx.Search == null) {
        notConfigured(ctx);
        return;
    }

    const id = ctx.request.params.get("id") orelse {
        badRequest(ctx, "missing :id");
        return;
    };

    ctx.Search.?.delete(ctx, COLLECTION, id) catch |e| {
        if (searchUpstreamError(ctx, e)) return;
        return e;
    };
    try ctx.response.json(.{ .status = "deleted", .id = id }, .{});
}

pub fn search(ctx: *Context) !void {
    if (ctx.Search == null) {
        notConfigured(ctx);
        return;
    }

    const q: []const u8 = blk: {
        if (ctx.request.method == .POST) break :blk ctx.request.body() orelse "";
        const qs = ctx.request.query() catch break :blk "";
        break :blk qs.get("q") orelse "";
    };

    const hits = ctx.Search.?.query(ctx, COLLECTION, q) catch |e| {
        if (searchUpstreamError(ctx, e)) return;
        return e;
    };
    defer ctx.allocator.free(hits);

    ctx.response.content_type = .JSON;
    try ctx.response.writer().writeAll(hits);
}

fn badRequest(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.bad_request);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

/// Map a Solr upstream failure to an explicit error response. The datasource no
/// longer logs; the status + message live on `ctx.Search.lastError()` and are
/// surfaced here. Returns `true` when handled (response already written).
fn searchUpstreamError(ctx: *Context, err: anyerror) bool {
    const is_solr = err == error.SolrIndexFailed or
        err == error.SolrQueryFailed or
        err == error.SolrDeleteFailed;
    if (!is_solr) return false;
    const detail = ctx.Search.?.lastError() orelse return false;
    ctx.response.setStatus(switch (detail.status) {
        401, 403 => .unauthorized,
        404 => .not_found,
        else => .bad_gateway,
    });
    ctx.response.json(.{ .err = "solr_upstream_failed", .status = detail.status, .message = detail.message }, .{}) catch {};
    return true;
}

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(
        .{
            .message = "SOLR_URL / SOLR_DEFAULT_COLLECTION not configured",
        },
        .{},
    ) catch {};
}
