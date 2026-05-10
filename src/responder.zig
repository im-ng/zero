const std = @import("std");
const Self = @This();
const Responder = @This();

pub fn Do(comptime ActionContext: type) type {
    if (ActionContext == void) {
        return *const fn () anyerror!void;
    }
    return *const fn (ActionContext) anyerror!void;
}

test "Do void type returns no-arg function pointer" {
    const Fn = Do(void);
    try std.testing.expect(Fn == *const fn () anyerror!void);
}

test "Do concrete type returns single-arg function pointer" {
    const Fn = Do(*u8);
    try std.testing.expect(Fn == *const fn (*u8) anyerror!void);
}
