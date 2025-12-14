const std = @import("std");
const zero = @import("zero");
const zul = zero.zul;
const Context = zero.Context;

pub const payload = struct {
    timestamp: []const u8,
    message: []const u8,
};

pub fn getUUID(ctx: *Context) ![]const u8 {
    const uuid = zul.UUID.v4();

    var buffer: []u8 = undefined;
    buffer = try ctx.allocator.alloc(u8, 36);
    buffer = uuid.toHexBuf(buffer, .lower);

    return buffer;
}

pub fn transform(ctx: *Context, p: *const payload) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(ctx.allocator);
    // defer out.deinit();

    // const fmt = std.json.fmt(p, .{ .whitespace = .indent_2 });
    // var writer = std.Io.Writer.Allocating.init(ctx.allocator);
    // try fmt.format(&writer.writer);

    // const encoded_message = try writer.toOwnedSlice();

    const json_formatter = std.json.fmt(p, .{});
    try json_formatter.format(&out.writer);
    try std.json.Stringify.value(p, .{}, &out.writer);

    return out.written();
}
