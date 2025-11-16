const std = @import("std");
const root = @import("zero");

const Scheduler = @This();
const Self = @This();
const regexp = root.regexp;
const RegExp = regexp.Regex;

matchSpaces: RegExp = undefined,
matchN: RegExp = undefined,
matchRange: RegExp = undefined,

pub fn create(allocator: std.mem.Allocator) !*Scheduler {
    const s = try allocator.create(Scheduler);

    s.* = {};
    s.matchSpaces = try RegExp.compile(allocator, "\\s+");
    s.matchN = try RegExp.compile(allocator, "(.*)/(\\d+)");
    s.matchRange = try RegExp.compile(allocator, "^(\\d+)-(\\d+)$");

    return s;
}
