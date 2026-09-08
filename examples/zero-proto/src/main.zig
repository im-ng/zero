const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

// Generated from proto/echo.proto by `zig build gen-proto`.
const pb = @import("proto/echo.pb.zig");

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.environ_map);

    try app.get("/", index);
    // Protobuf request/response: POST an `Echo` message (Content-Type:
    // application/x-protobuf) and get the same message back with `timestamp`
    // stamped by the server.
    try app.post("/echo", echo);

    try app.run();
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\POST /echo with a protobuf `Echo` body (Content-Type: application/x-protobuf).
        \\The server stamps `timestamp` and echoes the message back as protobuf.
    ;
}

pub fn echo(ctx: *Context) !void {
    const req = (try ctx.bindProto(pb.Echo)) orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };

    var out = req;
    out.timestamp = @intCast(std.Io.Timestamp.now(utils.io, .real).nanoseconds);
    try ctx.protobuf(out);
}
