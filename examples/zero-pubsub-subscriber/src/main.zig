const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

// Default topic. Override with PUBSUB_TOPIC in the environment.
const default_topic = "zero";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);

    // Subscribe through the unified interface; the backend (Kafka / MQTT / NATS)
    // is chosen by PUBSUB_BACKEND in configs/.env.
    try app.addPubSubSubscription(default_topic, onMessage);

    try app.run();
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ PubSub Subscriber Demo - Zero Framework
        \\ ==================================
        \\
        \\ Subscribed to topic "zero" (override PUBSUB_TOPIC or edit the call in
        \\ main.zig) through the unified ctx.pubsub interface. The backend is
        \\ selected by PUBSUB_BACKEND in configs/.env (Kafka / MQTT / NATS).
        \\ Incoming messages are logged as they arrive.
    ;
}

fn onMessage(ctx: *Context) !void {
    if (ctx.message) |msg| {
        switch (msg) {
            .mqtt => |m| logMsg(ctx, m.topic, m.payload orelse ""),
            .kafka => |m| logMsg(ctx, m.getTopic(), m.getPayload()),
            .nats => |m| logMsg(ctx, m.subject, m.payload),
            else => ctx.info("received message from an unsupported backend"),
        }
    }
}

fn logMsg(ctx: *Context, topic: []const u8, payload: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "received on [{s}] {s}", .{ topic, payload }) catch "decode error";
    ctx.info(line);
}
