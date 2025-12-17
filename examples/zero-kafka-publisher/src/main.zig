const std = @import("std");
const zero = @import("zero");

const Allocator = std.mem.Allocator;
const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const topicName = "zero-topic";

const Payload = struct {
    timestamp: []const u8,
    message: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

    try app.addCronJob("* * * * * *", "publisher-1", publishTask1);

    try app.run();
}

fn publishTask1(ctx: *Context) !void {
    const timestamp = try utils.sqlTimestampz(ctx.allocator);

    const messageKey = "publisher-1";

    const pl: Payload = .{
        .timestamp = timestamp,
        .message = "publisher message!",
    };

    const jp = try transform(ctx, &pl);
    ctx.info(jp);

    const topic = try ctx.KF.getTopicHandler(ctx, topicName);

    ctx.KF.publish(ctx, topic, messageKey, jp) catch |err| {
        var buffer: []u8 = undefined;
        buffer = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "Message published failed {}", .{err});
        return;
    };
}

fn transform(ctx: *Context, p: *const Payload) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(ctx.allocator);
    try std.json.Stringify.value(p, .{}, &out.writer);
    return out.written();
}
