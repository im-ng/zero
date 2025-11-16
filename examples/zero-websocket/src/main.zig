const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

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

pub fn main() !void {
    // var arean = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arean.deinit();

    // const allocator = arean.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

    try app.addWebsocket(socketHandler);

    try app.run();
}

pub fn socketHandler(ctx: *Context) !void {
    if (ctx.wsMessage) |msg| {
        ctx.info(msg);
    }

    try ctx.wsClient.write("hello!");
}
