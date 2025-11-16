const std = @import("std");
const logger = @This();
const Self = @This();
const root = @import("zero.zig");
const utils = root.utils;

var stdout: *std.Io.Writer = undefined;
var stdout_buffer: [512]u8 = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var mutex: std.Thread.Mutex = .{};

allocator: std.mem.Allocator,
logLevel: u8 = undefined,

pub fn custom(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock();
    defer mutex.unlock();
    nosuspend stdout.print(format, args) catch return;
    nosuspend stdout.flush() catch return;
}

pub fn create(allocator: std.mem.Allocator) !*logger {
    const l: *logger = try allocator.create(logger);
    errdefer allocator.destroy(l);

    stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    stdout = &stdout_writer.interface;

    l.allocator = allocator;
    l.logLevel = 1;

    return l;
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

    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.debug(debugFormat, .{ timestamp, message });
}

pub fn info(self: Self, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.info(infoFormat, .{ timestamp, message });
}

pub fn any(self: Self, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.info(anyFormat, .{ timestamp, message });
}

pub fn warn(self: Self, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }
    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.warn(warnFormat, .{ timestamp, message });
}

pub fn err(self: Self, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.err(errFormat, .{ timestamp, message });
}

pub fn fatal(self: Self, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    const timestamp = utils.timestampz(self.allocator) catch "";

    std.log.err(fatalFormat, .{ timestamp, message });
}

pub fn Debug(self: *Self, allocator: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 0) {
        return;
    }

    const timestamp = utils.timestampz(allocator) catch "";

    std.log.debug(debugFormat, .{ timestamp, message });
}

pub fn Info(self: *Self, allocator: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    const timestamp = utils.timestampz(allocator) catch "";

    std.log.info(infoFormat, .{ timestamp, message });
}

pub fn Any(self: *Self, allocator: std.mem.Allocator, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    const timestamp = utils.timestampz(allocator) catch "";

    std.log.info(anyFormat, .{ timestamp, message });
}

pub fn Warn(self: *Self, allocator: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }
    const timestamp = utils.timestampz(allocator) catch "";

    std.log.warn(warnFormat, .{ timestamp, message });
}

pub fn Err(self: *Self, allocator: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    const timestamp = utils.timestampz(allocator) catch "";

    std.log.err(errFormat, .{ timestamp, message });
}

pub fn Fatal(self: *Self, allocator: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    const timestamp = utils.timestampz(allocator) catch "";

    std.log.err(errFormat, .{ timestamp, message });
}
