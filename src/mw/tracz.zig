const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");

const tracz = @This();
const zul = root.zul;

allocator: std.mem.Allocator,

pub fn init(c: Config) !tracz {
    return .{
        .allocator = c.allocator,
    };
}

pub fn execute(_: *const tracz, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const uuid = zul.UUID.v4();

    var buffer: []u8 = undefined;
    buffer = try req.arena.alloc(u8, 36);

    buffer = uuid.toHexBuf(buffer, .lower);
    res.headers.add("X-Correlation-ID", buffer);

    return executor.next();
}

pub const Config = struct {
    allocator: std.mem.Allocator,
};
