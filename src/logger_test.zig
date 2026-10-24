const std = @import("std");
const logger = @import("logger.zig");

// Tests for logger.zig (501 lines) split out so the source file stays free of
// test code. Only tests reachable through `pub` symbols live here: the
// `redactInto` test stays in logger.zig because that helper is file-private.

test "create returns logger with default logLevel 1" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    try std.testing.expectEqual(@as(u8, 1), log.logLevel);
}

test "debug suppressed when logLevel > 0" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 1;
    log.debug("should not appear");
    try std.testing.expect(true);
}

test "info suppressed when logLevel > 1" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 2;
    log.info("should not appear");
    try std.testing.expect(true);
}

test "warn suppressed when logLevel > 2" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 3;
    log.warn("should not appear");
    try std.testing.expect(true);
}

test "err suppressed when logLevel > 3" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 4;
    log.err("should not appear");
    try std.testing.expect(true);
}

test "fatal suppressed when logLevel > 5" {
    const allocator = std.testing.allocator;
    const log = try logger.create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 5;
    log.fatal("should not appear");
    try std.testing.expect(true);
}
