const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const Memory = zero.memory;
const CPU = zero.cpu;
const Process = zero.process;
const Host = zero.host;
const utils = zero.utils;
const Builder = zero.zul.StringBuilder;
var mutex: std.Thread.Mutex = .{};
var connections: std.hash_map.StringHashMap(?*zero.WSClient) = undefined;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

    connections = std.hash_map.StringHashMap(?*zero.WSClient).init(allocator);

    try app.get("/host", host);

    try app.get("/cpu", cpu);

    try app.get("/status", status);

    try app.addWebsocket(connect);

    try app.addCronJob("*/10 * * * * *", "stream", stream);

    try app.run();
}

pub fn connect(ctx: *Context) !void {
    mutex.lock();
    defer mutex.unlock();
    try connections.put(ctx.request.header("sec-websocket-key").?, ctx.wsClient);
}

pub fn stream(ctx: *Context) !void {
    var iterator = connections.iterator();
    while (iterator.next()) |e| {
        const conn = e.value_ptr.*;
        if (conn == null) {
            ctx.info("connection is null");
            continue;
        }

        const c = conn.?;

        if (c._closed) {
            ctx.info("connection is closed");
            return;
        }

        var sb = Builder.init(ctx.allocator);
        defer sb.deinit();

        const timestamp = try utils.sqlTimestampz(ctx.allocator);

        try sb.write("<div hx-swap-oob=\"innerHTML:#update-timestamp\">");
        try sb.write("<p><i style='color: green' class='fa fa-circle'></i> ");
        try sb.write("Updated on  ");
        try sb.write(timestamp);
        try sb.write("</p></div>");
        try sb.write("<div hx-swap-oob=\"innerHTML:#system-data\">");
        try getHostInfo(ctx, &sb);
        try sb.write("</div>");
        try sb.write("<div hx-swap-oob=\"innerHTML:#cpu-data\">");
        try getCPUInfo(ctx, &sb);
        try sb.write("</div>");

        try c.write(sb.string());
    }
}

fn getCPUInfo(ctx: *Context, sb: *Builder) !void {
    const c = try CPU.info(ctx);

    try sb.write("<div class='cpu-data'>");
    try sb.write("<table class='table table-striped table-hover table-sm'><tbody>");
    try sb.write("<tr><td>Vendor Name:</td><td>");
    try sb.write(c.vendor_id);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Model Name:</td><td>");
    try sb.write(c.model_name);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Family:</td><td>");
    try sb.write(c.cpu_family);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Speed:</td><td>");
    try sb.write(c.cpu_speed);
    try sb.write(" Mhz</td></tr>");
    try sb.write("<tr><td>Cores:</td><td>");
    try sb.write(c.cpu_cores);
    try sb.write(" </td></tr>");

    try sb.write("</tbody></table></div>");
}

fn getHostInfo(ctx: *Context, sb: *Builder) !void {
    const h = try Host.usage(ctx);

    const path = try utils.combine(ctx.allocator, "/proc/{d}/status", .{std.c.getpid()});
    const p = try Process.usage(ctx.allocator, path);

    try sb.write("<div class='system-data'>");
    try sb.write("<table class='table table-striped table-hover table-sm'><tbody>");
    try sb.write("<tr><td>Operating System:</td> <td><i class='fa fa-brands fa-linux'></i>");
    try sb.write(h.name);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Platform:</td><td> <i class='fa fa-brands fa-debian'></i> ");
    try sb.write(h.version);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Platform:</td><td> <i class='fa fa-brands fa-debian'></i> ");
    try sb.write(h.id);
    try sb.write("</td></tr>");
    try sb.write("<tr><td>Hostname:</td><td> <i class='fa-solid fa-computer'></i> ");
    try sb.write(h.hostname);
    try sb.write("</td></tr>");

    try sb.write("<tr><td>Total Memory:</td><td> <i class='fa fa-brands fa-fedora'></i> ");
    const vmhwm = try utils.combine(ctx.allocator, "{d}", .{p.vmHWM});
    try sb.write(vmhwm);
    try sb.write("</td></tr>");

    try sb.write("<tr><td>Free Memory:</td><td> <i class='fa fa-brands fa-fedora'></i> ");
    const rssanon = try utils.combine(ctx.allocator, "{d}", .{p.rssAnon});
    try sb.write(rssanon);
    try sb.write("</td></tr>");

    try sb.write("</tbody></table></div>");
}

pub fn host(ctx: *Context) !void {
    const h = try Host.usage(ctx);
    try ctx.json(h);
}

pub fn cpu(ctx: *Context) !void {
    const c = try CPU.info(ctx);
    try ctx.json(c);
}

pub fn status(ctx: *Context) !void {
    const path = try utils.combine(ctx.allocator, "/proc/{d}/status", .{std.c.getpid()});
    const s = try Process.usage(ctx.allocator, path);
    try ctx.json(s);
}

pub fn memoryUsage(ctx: *Context) !void {
    const path = try utils.combine(ctx.allocator, "/proc/{d}/status", .{std.c.getpid()});
    const s = try Process.usage(ctx.allocator, path);
    try ctx.json(s);
}
