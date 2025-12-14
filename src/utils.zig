const std = @import("std");
const utils = @This();
const Self = @This();

const root = @import("zero.zig");
const dateTime = root.zdt.Datetime;

pub fn combine(allocator: std.mem.Allocator, comptime format: []const u8, value: anytype) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, format, value);
    return buffer;
}

pub fn toString(allocator: std.mem.Allocator, comptime format: []const u8, value: []const u8) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, format, .{value});
    return buffer;
}

pub fn toStringFromInt(allocator: std.mem.Allocator, comptime format: []const u8, value: i64) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, format, .{value});
    return buffer;
}

pub fn timestampz(allocator: std.mem.Allocator) ![]const u8 {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now };
    const time = epoch_seconds.getDaySeconds();
    const hour = time.getHoursIntoDay();
    const minute = time.getMinutesIntoHour();
    const second = time.getSecondsIntoMinute();
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 10);
    buffer = try std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
    return buffer;
}

pub fn sqlTimestampz(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 100);

    const now = dateTime.nowUTC();
    const yr = @as(u64, @intCast(now.year));

    //2000-01-01T07:24:22
    buffer = try allocator.alloc(u8, 20);
    buffer = try std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ yr, now.month, now.day, now.hour, now.minute, now.second });

    // try now.toString("%Y-%m-%dT%H:%M:%S", stdout); crashes

    return buffer;
}

pub fn DTtimestampz(allocator: std.mem.Allocator, timestamp: ?i64) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 100);
    defer allocator.free(buffer);

    const timestampns = @as(i128, @intCast(timestamp.?));
    const now = try dateTime.fromUnix(timestampns, .microsecond, null);
    const yr = @as(u64, @intCast(now.year));

    //2021-01-01T07:24:22
    buffer = try allocator.alloc(u8, 20);
    buffer = try std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ yr, now.month, now.day, now.hour, now.minute, now.second });
    return buffer;
}

pub fn toCString(allocator: std.mem.Allocator, value: []const u8) [*c]const u8 {
    var buffer: []u8 = undefined;
    buffer = allocator.alloc(u8, value.len) catch unreachable;
    buffer = std.fmt.bufPrint(buffer, "{s}", .{value}) catch unreachable;
    return @constCast(buffer.ptr);
}
