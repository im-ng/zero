const std = @import("std");
const Self = @This();
const tick = @This();

sec: u16 = undefined,
min: u16 = undefined,
hour: u16 = undefined,
day: u16 = undefined,
month: u16 = undefined,
year: u16 = undefined,
dayOfWeek: u16 = undefined,

test "tick struct initialization" {
    const t = tick{
        .sec = 30,
        .min = 15,
        .hour = 10,
        .day = 5,
        .month = 3,
        .year = 2024,
        .dayOfWeek = 1,
    };
    try std.testing.expectEqual(@as(u16, 30), t.sec);
    try std.testing.expectEqual(@as(u16, 15), t.min);
    try std.testing.expectEqual(@as(u16, 10), t.hour);
    try std.testing.expectEqual(@as(u16, 5), t.day);
    try std.testing.expectEqual(@as(u16, 3), t.month);
    try std.testing.expectEqual(@as(u16, 2024), t.year);
    try std.testing.expectEqual(@as(u16, 1), t.dayOfWeek);
}
