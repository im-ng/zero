const std = @import("std");
const root = @import("../zero.zig");

const Scheduler = @This();
const Self = @This();
const regexp = root.regexp;
const RegExp = regexp.Regex;

matchSpaces: RegExp = undefined,
matchN: RegExp = undefined,
matchRange: RegExp = undefined,

pub fn create(allocator: std.mem.Allocator) !*Scheduler {
    const s = try allocator.create(Scheduler);

    s.matchSpaces = try RegExp.compile(allocator, "\\s+");
    s.matchN = try RegExp.compile(allocator, "(.*)/(\\d+)");
    s.matchRange = try RegExp.compile(allocator, "^(\\d+)-(\\d+)$");

    return s;
}

test "create compiles regex patterns" {
    const allocator = std.testing.allocator;
    const s = try create(allocator);
    defer {
        s.matchSpaces.deinit();
        s.matchN.deinit();
        s.matchRange.deinit();
        allocator.destroy(s);
    }
    try std.testing.expectEqualStrings("\\s+", s.matchSpaces.string);
    try std.testing.expectEqualStrings("(.*)/(\\d+)", s.matchN.string);
    try std.testing.expectEqualStrings("^(\\d+)-(\\d+)$", s.matchRange.string);
}
