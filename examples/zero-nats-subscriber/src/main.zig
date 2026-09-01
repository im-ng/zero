const std = @import("std");
const zero = @import("zero");

const Allocator = std.mem.Allocator;
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
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.environ_map);

    try app.get("/", index);

    try app.addPubSubSubscription("zero", onMessage);

    try app.run();
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ NATS Subscriber Demo - Zero Framework
        \\ ================================
        \\
        \\ Subscribed to subject: zero
        \\ Messages are logged as they arrive.
    ;
}

fn onMessage(ctx: *Context) !void {
    if (ctx.message) |message| {
        const m = message.nats;
        var buffer: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buffer,
            "received on [{s}] {s}",
            .{ m.subject, m.payload },
        ) catch "decode error";
        ctx.info(msg);
    }
}
