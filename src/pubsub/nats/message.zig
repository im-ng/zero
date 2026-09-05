const std = @import("std");
const root = @import("../../zero.zig");

pub const natsMessage = struct {
    context: *root.Context,
    subject: []const u8,
    payload: []const u8,
};
