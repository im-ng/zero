const root = @import("../../zero.zig");
const Self = @This();
const ZeroSubscriber = @This();

name: []const u8,
topic: []const u8,
packetIdentifier: u16 = 0,
exec: *const fn (*root.Context) anyerror!void = undefined,
