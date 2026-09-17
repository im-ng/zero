const std = @import("std");
const root = @import("../zero.zig");
const rdz = @This();
const Self = @This();

const rediz = root.rediz;
const SET = rediz.commands.strings.SET;
const OrErr = rediz.types.OrErr;
const Client = rediz.Client;

allocator: std.mem.Allocator,
log: *root.logger = undefined,
metricz: *root.metricz = undefined,
rbuf: [1024]u8 = undefined,
wbuf: [1024]u8 = undefined,

pub fn create(allocator: std.mem.Allocator) !*rdz {
    const rz = try allocator.create(rdz);
    errdefer allocator.destroy(rz);
    return rz;
}

pub fn close(self: *Self) !void {
    // No live client is owned by this wrapper (the active Redis connection is
    // held by `container.redis`); nothing to tear down here. Previously this
    // recursively called itself, which would overflow the stack.
    _ = self;
}
