const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

// Route every std.log call through zero's custom sink, which mirrors each record
// into OpenTelemetry logs when otel_experimental=true.
pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

// Response shape for the self-call echo endpoint. The outbound client injects a
// W3C `traceparent` header; /echo reads it back so we can prove propagation.
// Note: ctx.json wraps the payload under a `data` key.
const EchoResp = struct { data: struct { traceparent: []const u8 } };

fn sendText(ctx: *Context, body: []const u8) !void {
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .TEXT;
    ctx.response.body = body;
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    // Outbound self-call target: proves client->server traceparent propagation with
    // no external network. "self" points at this very server.
    try app.addHttpService("self", "http://localhost:8080", .{});

    try app.get("/", index);
    try app.get("/echo", echo);
    try app.get("/outbound", outbound);
    try app.get("/log", logDemo);

    try app.run();
}

// Server span + response traceparent + a log line.
fn index(ctx: *Context) !void {
    ctx.info("handling GET /");
    try sendText(ctx, "ok");
}

// Returns the incoming traceparent so a caller can confirm it propagated. JSON so
// the outbound client (which deserializes the response) can read it back.
fn echo(ctx: *Context) !void {
    const tp = ctx.request.header("traceparent") orelse "(none)";
    try ctx.json(.{ .traceparent = tp });
}

// Outbound call: the client injects the active traceparent; /echo reflects it.
fn outbound(ctx: *Context) !void {
    const svc = ctx.getService("self") orelse return ctx.err("self service not registered");
    const resp = try svc.get(ctx, EchoResp, "/echo", null, null);
    const tp = resp.?.data.traceparent;
    ctx.info("outbound call propagated traceparent");
    try sendText(ctx, tp);
}

// Exercises the logs bridge across levels.
fn logDemo(ctx: *Context) !void {
    ctx.debug("debug message");
    ctx.info("info message");
    ctx.warn("warn message");
    ctx.err("error message");
    try sendText(ctx, "logged");
}
