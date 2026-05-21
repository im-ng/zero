const std = @import("std");

pub const Response = struct {
    message: anyopaque,
};

pub const ErrData = struct {
    data: Response,
};

test "Response struct can hold pointer to data" {
    var val: i32 = 42;
    const resp = Response{ .message = @as(anyopaque, @ptrCast(&val)) };
    const ptr: *i32 = @ptrCast(@alignCast(&resp.message));
    try std.testing.expectEqual(@as(i32, 42), ptr.*);
}

test "ErrData wraps Response correctly" {
    var val: i32 = 99;
    const resp = Response{ .message = @as(anyopaque, @ptrCast(&val)) };
    const errData = ErrData{ .data = resp };
    const ptr: *i32 = @ptrCast(@alignCast(&errData.data.message));
    try std.testing.expectEqual(@as(i32, 99), ptr.*);
}
