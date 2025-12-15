const std = @import("std");
const zero = @import("zero");
const zul = zero.zul;
const Context = zero.Context;

pub const Payload = struct {
    timestamp: []const u8,
    message: []const u8,
};

pub fn transform(ctx: *Context, p: *const Payload) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(ctx.allocator);
    try std.json.Stringify.value(p, .{}, &out.writer);
    return out.written();
}
