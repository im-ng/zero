const std = @import("std");
const root = @import("../../zero.zig");

pub const natsSubscriber = struct {
    topic: []const u8,
    name: []const u8,
    exec: *const fn (*root.Context) anyerror!void,
};
