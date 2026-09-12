const std = @import("std");
const logger = @This();
const Self = @This();
const root = @import("zero.zig");
const utils = root.utils;

var mutex: std.Io.Mutex = .init;

/// When true, log lines are emitted as JSON (`{"ts":...,"level":...,"msg":...}`)
/// instead of the default colorized text. Controlled by `LOG_FORMAT=json`.
var json_format: bool = false;

allocator: std.mem.Allocator,
logLevel: u8 = undefined,

/// Formats `value` into `buf`, using `{s}` for string-like values and `{any}`
/// otherwise, so non-string payloads (e.g. structs) still serialize in JSON mode.
fn formatArg(buf: []u8, value: anytype) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return std.fmt.bufPrint(buf, "{s}", .{value}) catch "";
        },
        .array => |arr| {
            if (arr.child == u8) return std.fmt.bufPrint(buf, "{s}", .{value}) catch "";
        },
        else => {},
    }
    return std.fmt.bufPrint(buf, "{any}", .{value}) catch "";
}

/// Writes `s` to `out` with JSON string escaping (`"`, `\`, control chars).
fn writeJsonEscaped(out: std.Io.File, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.writeStreamingAll(utils.io, "\\\""),
            '\\' => try out.writeStreamingAll(utils.io, "\\\\"),
            '\n' => try out.writeStreamingAll(utils.io, "\\n"),
            '\r' => try out.writeStreamingAll(utils.io, "\\r"),
            '\t' => try out.writeStreamingAll(utils.io, "\\t"),
            else => try out.writeStreamingAll(utils.io, &.{c}),
        }
    }
}

pub fn custom(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock(utils.io) catch {};
    defer mutex.unlock(utils.io);
    const out = std.Io.File.stdout();

    if (json_format) {
        var ts_buf: [64]u8 = undefined;
        const ts = if (args.len >= 1) formatArg(&ts_buf, args[0]) else "";
        var msg_buf: [2048]u8 = undefined;
        const msg = if (args.len >= 2) formatArg(&msg_buf, args[1]) else "";

        out.writeStreamingAll(utils.io, "{\"ts\":\"") catch return;
        writeJsonEscaped(out, ts) catch return;
        out.writeStreamingAll(utils.io, "\",\"level\":\"") catch return;
        out.writeStreamingAll(utils.io, @tagName(level)) catch return;
        out.writeStreamingAll(utils.io, "\",\"msg\":\"") catch return;
        writeJsonEscaped(out, msg) catch return;
        out.writeStreamingAll(utils.io, "\"}\n") catch return;
        return;
    }

    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch "log format error";
    out.writeStreamingAll(utils.io, msg) catch return;
}

pub fn create(allocator: std.mem.Allocator) !*logger {
    const l: *logger = try allocator.create(logger);
    errdefer allocator.destroy(l);

    l.allocator = allocator;
    l.logLevel = 1;

    return l;
}

/// Enables (`true`) or disables (`false`) JSON structured log output. Driven by
/// the `LOG_FORMAT=json` app config (see `app.zig`).
pub fn setJsonFormat(enabled: bool) void {
    json_format = enabled;
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}

const debugFormat = "\x1b[38;5;8mDEBUG\x1b[0m [{s}] {s}\n";
const infoFormat = "\x1b[38;5;6m INFO\x1b[0m [{s}] {s}\n";
const anyFormat = "\x1b[38;5;6m INFO\x1b[0m [{s}] {any}\n";
const warnFormat = "\x1b[38;5;220m WARN\x1b[0m [{s}] {s}\n";
const errFormat = "\x1b[38;5;160mERROR\x1b[0m [{s}] {s}\n";
const fatalFormat = "\x1b[38;5;140mFATAL\x1b[0m [{s}] {s}\n";

pub fn debug(self: Self, message: []const u8) void {
    if (self.logLevel > 0) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.debug(debugFormat, .{ ts, message });
}

pub fn info(self: Self, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.info(infoFormat, .{ ts, message });
}

pub fn any(self: Self, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.info(anyFormat, .{ ts, message });
}

pub fn warn(self: Self, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }
    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.warn(warnFormat, .{ ts, message });
}

pub fn err(self: Self, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.err(errFormat, .{ ts, message });
}

pub fn fatal(self: Self, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.err(fatalFormat, .{ ts, message });
}

pub fn Debug(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 0) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.debug(debugFormat, .{ ts, message });
}

pub fn Info(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.info(infoFormat, .{ ts, message });
}

pub fn Any(self: *Self, _: std.mem.Allocator, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.info(anyFormat, .{ ts, message });
}

pub fn Warn(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.warn(warnFormat, .{ ts, message });
}

pub fn Err(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.err(errFormat, .{ ts, message });
}

pub fn Fatal(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.err(errFormat, .{ ts, message });
}

test "create returns logger with default logLevel 1" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    try std.testing.expectEqual(@as(u8, 1), log.logLevel);
}

test "debug suppressed when logLevel > 0" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 1;
    log.debug("should not appear");
    try std.testing.expect(true);
}

test "info suppressed when logLevel > 1" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 2;
    log.info("should not appear");
    try std.testing.expect(true);
}

test "warn suppressed when logLevel > 2" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 3;
    log.warn("should not appear");
    try std.testing.expect(true);
}

test "err suppressed when logLevel > 3" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 4;
    log.err("should not appear");
    try std.testing.expect(true);
}

test "fatal suppressed when logLevel > 5" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 5;
    log.fatal("should not appear");
    try std.testing.expect(true);
}
