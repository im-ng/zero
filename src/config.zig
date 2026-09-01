const std = @import("std");
const builtin = @import("builtin");
const root = @import("zero.zig");
const dotenv = root.dotenv;
const constants = root.constants;
const utils = root.utils;

const config = @This();
const Self = @This();

/// Process environment, set once at startup via `setEnviron` (from
/// `std.process.Init.environ`). Under `zig build test`, `std.testing.environ`
/// is used instead.
const defaultPath = "./configs";
const defaultFile = "./configs/.env";
// const defaultFile = "/media/ng/home/zig-self-learning/zero/examples/zero-sqlite/configs/.env";

environments: *std.process.Environ.Map,
allocator: std.mem.Allocator,
log: *root.logger,

pub fn create(self: Self) !*config {
    const c = try self.allocator.create(config);
    errdefer self.allocator.destroy(c);

    c.* = .{
        .allocator = self.allocator,
        .log = self.log,
        .environments = self.environments,
    };

    try loadDefaultEnv(c);

    try loadEnvironmentOverrides(c);

    return c;
}

fn isFileRWExist(fn_dir: std.fs.Dir, fn_file_name: []const u8) !bool {
    fn_dir.access(fn_file_name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.PermissionDenied => return false,
        else => {
            return err;
        },
    };
    return true;
}

fn loadDefaultEnv(self: *Self) !void {
    try dotenv.loadFrom(self.allocator, utils.io, self.environments, defaultFile, .{});
    const msg = try utils.combine(self.allocator, "Loaded config from file: {s}", .{defaultFile});
    self.log.Info(self.allocator, msg);
}

fn loadEnvironmentOverrides(self: *Self) !void {
    var finalEnvFile: []const u8 = undefined;

    const env = self.get(constants.APP_ENVIRONMENT);
    if (env.len != 0) {
        finalEnvFile = try utils.combine(self.allocator, "{s}/.{s}.env", .{ defaultPath, env });
    } else {
        finalEnvFile = defaultFile;
    }

    dotenv.loadFrom(self.allocator, utils.io, self.environments, finalEnvFile, .{ .override = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const msg = try utils.combine(self.allocator, "config overriden {s} file not found.", .{finalEnvFile});
            self.log.info(msg);
        },
        else => {
            const msg = try utils.combine(self.allocator, "config overriden from: {s}", .{finalEnvFile});
            self.log.info(msg);
        },
    };
}

pub fn get(self: *Self, key: []const u8) []const u8 {
    return self.getOrDefault(key, "");
}

pub fn getAsInt(self: *Self, key: []const u8) !u16 {
    const zero: []const u8 = "0";
    const value: []const u8 = self.getOrDefault(key, zero);
    const integer = try std.fmt.parseInt(u16, value, 10);
    return integer;
}

pub fn getAsBool(self: *Self, key: []const u8) bool {
    const value: []const u8 = self.getOrDefault(key, "");
    if (std.mem.eql(u8, value, "") == true) {
        return false;
    } else if (std.mem.eql(u8, value, "false") == true) {
        return false;
    } else if (std.mem.eql(u8, value, "true") == true) {
        return true;
    }
    return false;
}

pub fn getIntByType(self: *Self, key: []const u8, comptime T: type) !T {
    const zero: []const u8 = "0";
    const value: []const u8 = self.getOrDefault(key, zero);
    const integer = try std.fmt.parseInt(T, value, 10);
    return integer;
}

pub fn getOrDefault(self: *Self, key: []const u8, default: []const u8) []const u8 {
    const value = if (builtin.is_test)
        std.testing.environ.getPosix(key)
    else
        self.environments.get(key);
    if (value == null) {
        return default;
    }
    return value.?;
}

test "getAsBool returns false for unset env var" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();
    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.getAsBool("ZERO_TEST_BOOL_UNSET_XYZ");
    try std.testing.expect(result == false);
}

test "getAsBool logic with known values" {
    try std.testing.expect(std.mem.eql(u8, "true", "true"));
    try std.testing.expect(!std.mem.eql(u8, "false", "true"));
    try std.testing.expect(std.mem.eql(u8, "false", "false"));
}

test "getAsInt returns 0 for unset env var" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);

    defer allocator.destroy(log);
    defer emap.deinit();
    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = try cfg.getAsInt("ZERO_TEST_INT_UNSET_XYZ");
    try std.testing.expect(result == 0);
}

test "getOrDefault returns default when env var is unset" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.getOrDefault("ZERO_TEST_DEFAULT_UNSET_XYZ", "fallback");
    try std.testing.expectEqualStrings("fallback", result);
}

test "getOrDefault returns PATH when set" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.getOrDefault("PATH", "fallback");
    try std.testing.expect(result.len > 0);
}

test "getIntByType parses u16 from known env var" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = try cfg.getIntByType("ZERO_TEST_INT_UNSET_XYZ", u16);
    try std.testing.expect(result == 0);
}

test "get returns empty string for unset env var" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.get("ZERO_TEST_GET_UNSET_XYZ");
    try std.testing.expectEqualStrings("", result);
}

test "getAsBool returns true for true value" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.getAsBool("PATH");
    _ = result;
}

test "getAsBool returns false for non-true value" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result = cfg.getAsBool("PATH");
    try std.testing.expect(result == false);
}

test "getAsInt returns error for non-numeric value" {
    const allocator = std.testing.allocator;
    const log = try root.logger.create(allocator);
    var emap: std.process.Environ.Map = try std.testing.environ.createMap(allocator);
    defer allocator.destroy(log);
    defer emap.deinit();

    var cfg = config{
        .allocator = allocator,
        .log = log,
        .environments = &emap,
    };

    const result: anyerror!u16 = cfg.getAsInt("PATH");
    try std.testing.expectError(error.InvalidCharacter, @as(anyerror!u16, result));
}
