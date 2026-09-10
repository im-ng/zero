const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");

const tracz = @This();
const zul = root.zul;
const utils = root.utils;

allocator: std.mem.Allocator,

pub fn init(c: Config) !tracz {
    return .{
        .allocator = c.allocator,
    };
}

pub fn execute(_: *const tracz, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // Reuse the caller's correlation ID if provided, otherwise mint a new one.
    const id = req.header("X-Correlation-ID") orelse blk: {
        const uuid = zul.UUID.v4(utils.io);
        const buf = try req.arena.alloc(u8, 36);
        break :blk uuid.toHexBuf(buf, .lower);
    };

    // Echo it on the response and stamp the inbound request so downstream
    // outbound calls (HTTP client, pub/sub) can read and propagate it.
    res.headers.add("X-Correlation-ID", id);
    req.headers.add("X-Correlation-ID", id);

    return executor.next();
}

pub const Config = struct {
    allocator: std.mem.Allocator,
};

test "tracz Config struct can be initialized" {
    const allocator = std.testing.allocator;
    const cfg = Config{ .allocator = allocator };
    try std.testing.expectEqual(allocator, cfg.allocator);
}

test "tracz init returns struct with allocator" {
    const allocator = std.testing.allocator;
    const cfg = Config{ .allocator = allocator };
    const t = try init(cfg);
    try std.testing.expectEqual(allocator, t.allocator);
}
