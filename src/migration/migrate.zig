const std = @import("std");
const migrate = @This();
const Self = @This();

const root = @import("../zero.zig");
const util = root.utils;

migrationNumber: i64 = undefined,
run: *const fn (*root.Context) anyerror!void = undefined,
