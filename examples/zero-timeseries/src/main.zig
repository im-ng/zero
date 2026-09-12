const std = @import("std");
const zero = @import("zero");

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

    const app = try App.new(allocator, init.environ_map);

    try app.get("/", index);
    try app.post("/points", writePoint);
    try app.post("/write", writeLine);
    try app.get("/query", queryFlux);
    try app.post("/query", queryFlux);

    try app.run();
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
        \\   GET  /query?q=<flux>   run a Flux query
        \\   POST /query            run a Flux query (request body)
        \\
        \\ Set INFLUXDB_URL / INFLUXDB_ORG / INFLUXDB_BUCKET in configs/.env.
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
        try ts.write(ctx, p.measurement, p.tags, p.fields, p.ts);
        try ctx.response.json(.{ .status = "written" }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn writeLine(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const body = ctx.request.body() orelse "";
        var it = std.mem.tokenizeScalar(u8, body, ' ');
        const series = it.next() orelse {
            badRequest(ctx, "invalid line protocol");
            return;
        };
        const fields = it.next() orelse {
            badRequest(ctx, "invalid line protocol");
            return;
        };
        const ts_str = it.next();
        var sit = std.mem.splitScalar(u8, series, ',');
        const measurement = sit.next() orelse "";
        const tags = sit.rest();
        const ts_val: ?i64 = if (ts_str) |t|
            std.fmt.parseInt(i64, std.mem.trim(u8, t, " \r\n"), 10) catch null
        else
            null;
        try ts.write(ctx, measurement, tags, fields, ts_val);
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
        const csv = try ts.query(ctx, q);
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

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(.{ .message = "INFLUXDB_URL / INFLUXDB_ORG / INFLUXDB_BUCKET not configured" }, .{}) catch {};
}
