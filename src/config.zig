const std = @import("std");
const root = @import("zero.zig");
const dotenv = root.dotenv;
const constants = root.constants;
const utils = root.utils;

const config = @This();
const Self = @This();

const defaultPath = "./configs";
const defaultFile = "./configs/.env";
// const defaultFile = "/media/ng/home/zig-self-learning/zero/examples/zero-kafka-subscriber/configs/.env";

allocator: std.mem.Allocator,
log: *root.logger,

pub fn create(self: Self) !*config {
    const c = try self.allocator.create(config);
    errdefer self.allocator.destroy(c);

    c.* = .{
        .allocator = self.allocator,
        .log = self.log,
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
    try dotenv.loadFrom(self.allocator, defaultFile, .{});
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

    dotenv.loadFrom(self.allocator, finalEnvFile, .{ .override = true }) catch |err| switch (err) {
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

pub fn getOrDefault(_: *Self, key: []const u8, default: []const u8) []const u8 {
    const value = std.posix.getenv(key);
    if (value == null) {
        return default;
    }
    return value.?;
}
