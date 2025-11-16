const root = @import("../../zero.zig");
const Self = @This();
const Message = @This();

context: *root.Context = undefined,
topic: []const u8,
payload: ?[]const u8, // convert to comptime T
