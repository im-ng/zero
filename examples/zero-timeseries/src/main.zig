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
    try app.post("/points", writePoint);
    try app.post("/write", writeLine);
    try app.get("/query", queryFlux);
    try app.post("/query", queryFlux);

    // Create the bucket (v3 database) at startup so the first write succeeds.
    app.onStartup(ensureBucket);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ InfluxDB (time-series) demo.
        \\ Routes:
        \\   POST /points    write a point (JSON body:
        \\                    {"measurement":"cpu","tags":"host=server1",
        \\                     "fields":"usage=42.1","ts":null})
        \\   POST /write    write a point (InfluxDB line protocol body:
        \\                    cpu,host=server1 usage=42.1)
        \\   GET  /query?q=<sql>   run a SQL/InfluxQL query
        \\   POST /query            run a SQL/InfluxQL query (request body)
        \\
        \\ Set INFLUXDB_URL / INFLUXDB_BUCKET in configs/.env.
    ;
}

pub fn writePoint(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const body = ctx.request.body() orelse "";
        const parsed = std.json.parseFromSlice(struct {
            measurement: []const u8,
            tags: []const u8 = "",
            fields: []const u8,
            ts: ?i64 = null,
        }, ctx.allocator, body, .{}) catch {
            badRequest(ctx, "invalid JSON body");
            return;
        };
        defer parsed.deinit();
        const p = parsed.value;

        // The backend takes one line-protocol statement, so assemble it here. A
        // leading comma on `tags` is optional.
        const sep = if (p.tags.len > 0 and p.tags[0] != ',') "," else "";
        const base = if (p.tags.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "{s}{s}{s} {s}", .{ p.measurement, sep, p.tags, p.fields })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ p.measurement, p.fields });
        const line = if (p.ts) |tsv|
            try std.fmt.allocPrint(ctx.allocator, "{s} {d}", .{ base, tsv })
        else
            base;
        if (p.ts != null) ctx.allocator.free(base);
        defer ctx.allocator.free(line);

        ts.write(ctx, line) catch |e| {
            if (timeseriesUpstreamError(ctx, e)) return;
            return e;
        };
        try ctx.response.json(.{ .status = "written" }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn writeLine(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const line = ctx.request.body() orelse "";
        if (line.len == 0) {
            badRequest(ctx, "empty line protocol");
            return;
        }
        ts.write(ctx, line) catch |e| {
            if (timeseriesUpstreamError(ctx, e)) return;
            return e;
        };
        try ctx.response.json(.{ .status = "written" }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn queryFlux(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const q: []const u8 = blk: {
            if (ctx.request.method == .POST) break :blk ctx.request.body() orelse "";
            const qs = ctx.request.query() catch break :blk "";
            break :blk qs.get("q") orelse "";
        };
        const csv = ts.query(ctx, q) catch |e| {
            if (timeseriesUpstreamError(ctx, e)) return;
            return e;
        };
        defer ctx.allocator.free(csv);
        ctx.response.content_type = .TEXT;
        try ctx.response.writer().writeAll(csv);
    } else {
        notConfigured(ctx);
    }
}

fn badRequest(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.bad_request);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

/// Map an InfluxDB upstream failure to an explicit error response. The datasource
/// no longer logs; status + message live on `ts.lastError()` and are surfaced
/// here. Returns `true` when handled (response already written).
fn timeseriesUpstreamError(ctx: *Context, err: anyerror) bool {
    const is_influx = err == error.InfluxDBWriteFailed or
        err == error.InfluxDBQueryFailed;
    if (!is_influx) return false;
    const detail = ctx.Timeseries.?.lastError() orelse return false;
    ctx.response.setStatus(switch (detail.status) {
        401, 403 => .unauthorized,
        404 => .not_found,
        else => .bad_gateway,
    });
    ctx.response.json(.{ .err = "influxdb_upstream_failed", .status = detail.status, .message = detail.message }, .{}) catch {};
    return true;
}

/// Startup hook: ensure the configured v3 database exists before serving
/// traffic. Failures are logged but non-fatal, so the app still boots even if
/// the server is momentarily unreachable.
fn ensureBucket(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const bucket = ctx.container.config.get("INFLUXDB_BUCKET");
        if (std.mem.eql(u8, bucket, "")) return;
        ts.createDatabase(ctx, bucket) catch |e| {
            std.log.warn("timeseries: could not ensure bucket '{s}': {s}", .{ bucket, @errorName(e) });
        };
    }
}

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(.{ .message = "INFLUXDB_URL / INFLUXDB_BUCKET not configured" }, .{}) catch {};
}
