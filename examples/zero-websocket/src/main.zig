const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var ix: usize = 0;
    std.log.err("=== Stack Trace ==============", .{});
    while (it.next()) |frame| : (ix += 1) {
        std.log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }
}

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator, init.environ_map);

    try app.addWebsocket(socketHandler);

    try app.run();
}

pub fn socketHandler(ctx: *Context) !void {
    if (ctx.wsMessage) |msg| {
        ctx.info(msg);

        try ctx.wsClient.write(msg);
        return;
    }

    try ctx.wsClient.write("hello!");
}
