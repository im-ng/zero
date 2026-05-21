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

test "combine produces correct output" {
    const allocator = std.heap.page_allocator;
    const result = try combine(allocator, "hello {s}", .{"world"});
    try std.testing.expectEqualStrings("hello world", result[0..11]);
}

test "combine formats integer" {
    const allocator = std.heap.page_allocator;
    const result = try combine(allocator, "count: {d}", .{42});
    try std.testing.expectEqualStrings("count: 42", result[0..9]);
}

test "toString wraps string in format" {
    const allocator = std.heap.page_allocator;
    const result = try toString(allocator, "item: {s}", "test");
    try std.testing.expectEqualStrings("item: test", result[0..10]);
}

test "toStringFromInt formats integer" {
    const allocator = std.heap.page_allocator;
    const result = try toStringFromInt(allocator, "val: {d}", 99);
    try std.testing.expectEqualStrings("val: 99", result[0..7]);
}

test "timestampz returns HH:MM:SS format" {
    const allocator = std.heap.page_allocator;
    const result = try timestampz(allocator);
    try std.testing.expect(result.len == 8);
    try std.testing.expect(result[2] == ':');
    try std.testing.expect(result[5] == ':');
}

test "sqlTimestampz returns ISO-like format" {
    const allocator = std.heap.page_allocator;
    const result = try sqlTimestampz(allocator);
    try std.testing.expect(result.len == 19);
    try std.testing.expect(result[4] == '-');
    try std.testing.expect(result[7] == '-');
    try std.testing.expect(result[10] == 'T');
    try std.testing.expect(result[13] == ':');
    try std.testing.expect(result[16] == ':');
}

test "toCString returns null-terminated pointer" {
    const allocator = std.heap.page_allocator;
    const result: [*c]const u8 = toCString(allocator, "hello");
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(result, 0));
}

test "toCString handles empty string" {
    const allocator = std.heap.page_allocator;
    const result: [*c]const u8 = toCString(allocator, "x");
    try std.testing.expectEqualStrings("x", std.mem.sliceTo(result, 0));
}

test "combine handles empty format" {
    const allocator = std.heap.page_allocator;
    const result = try combine(allocator, "{s}", .{""});
    try std.testing.expectEqualStrings("", result[0..0]);
}
