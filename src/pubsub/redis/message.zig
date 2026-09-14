const root = @import("../../zero.zig");

/// Inbound message surfaced to Redis Pub/Sub subscribe hooks.
pub const redisMessage = struct {
    context: *root.Context,
    subject: []const u8,
    payload: []const u8,
};
