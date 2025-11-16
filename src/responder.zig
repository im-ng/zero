const std = @import("std");
const Self = @This();
const Responder = @This();

pub fn Do(comptime ActionContext: type) type {
    if (ActionContext == void) {
        return *const fn () anyerror!void;
    }
    return *const fn (ActionContext) anyerror!void;
}
