const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

// Default topic. Override per request with ?topic=, or set PUBSUB_TOPIC in the
// environment (read by the framework and available via ctx.container.config).
const default_topic = "zero";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);
    try app.get("/publish", publish);
    try app.post("/publish", publish);

    // Emit a heartbeat every 5s so the demo flows without manual calls.
    try app.addCronJob("*/5 * * * * *", "heartbeat", publishHeartbeat);

    try app.run();
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ PubSub Publisher Demo - Zero Framework
        \\ =================================
        \\
        \\ Publishes through the unified ctx.pubsub interface. The backend
        \\ (Kafka / MQTT / NATS) is selected by PUBSUB_BACKEND in configs/.env.
        \\
        \\ GET  /publish?message=hello&topic=zero   publish via query string
        \\ POST /publish  (raw body = message; ?topic= overrides)   publish body
        \\ A heartbeat is published to "zero" every 5s automatically.
    ;
}

fn publish(ctx: *Context) !void {
    if (!ctx.getPubSubAvailability()) {
        try ctx.response.json(.{ .status = "error", .message = "pubsub not configured: set PUBSUB_BACKEND" }, .{});
        return;
    }

    const body = ctx.request.body() orelse "";
    const params = ctx.request.query() catch null;

    const message = if (body.len > 0) body else if (params) |p| p.get("message") orelse "" else "";
    const topic = if (params) |p| p.get("topic") orelse default_topic else default_topic;

    if (message.len == 0) {
        try ctx.response.json(.{ .status = "error", .message = "missing message (?message= or POST body)" }, .{});
        return;
    }

    ctx.pubsub.Publish(topic, message) catch |err| {
        try ctx.response.json(.{ .status = "error", .message = @errorName(err) }, .{});
        return;
    };

    try ctx.response.json(.{ .status = "published", .topic = topic, .bytes = message.len }, .{});
}

fn publishHeartbeat(ctx: *Context) !void {
    if (!ctx.getPubSubAvailability()) return;
    const ts = utils.sqlTimestampz(ctx.allocator) catch "heartbeat";
    ctx.pubsub.Publish(default_topic, ts) catch |err| {
        ctx.info(@errorName(err));
    };
}
