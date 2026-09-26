const std = @import("std");
const testing = std.testing;
const root = @import("../zero.zig");
const utils = root.utils;
const Context = root.Context;

/// Retrieves the current host statistics.
///
/// Cross-platform: delegates to `zf.gather` so this works on macOS as well as
/// Linux, instead of reading /etc/os-release and /etc/hostname directly.
///
/// Returns a `Host` struct with the current host info.
pub fn usage(ctx: *Context) !Host {
    var sys = root.sysinfo.gather.gather(ctx.allocator, utils.io);
    defer sys.deinit();

    const a = ctx.allocator;
    var host = Host{};
    host.name = dupeOrEmpty(a, sys.os_name);
    host.id = dupeOrEmpty(a, sys.distro_id);
    host.version = dupeOrEmpty(a, sys.os_version);
    host.hostname = dupeOrEmpty(a, sys.hostname);
    return host;
}

/// Dupes `value` into `allocator`, or returns an empty slice when `value` is null.
fn dupeOrEmpty(allocator: std.mem.Allocator, value: ?[]const u8) []const u8 {
    if (value) |v| return allocator.dupe(u8, v) catch "";
    return "";
}

/// Sets the value of a field in the `MemUsage` struct.
///
/// - `value`: A pointer to the field to be set.
/// - `line`: The line of text containing the field value.
/// - `section`: The section of the line that contains the field name.
fn setValue(
    allocator: std.mem.Allocator,
    comptime T: type,
    value: *T,
    line: []const u8,
    section: []const u8,
) !void {
    if (std.mem.startsWith(u8, line, section)) {
        const c = std.mem.trim(u8, line[section.len..], " ");

        var builder = std.array_list.Managed(u8).init(allocator);
        defer builder.deinit();

        for (c) |char| {
            if (char == '\n') {
                continue;
            } else if (char == '"') {
                continue;
            } else {
                try builder.append(char);
            }
        }
        const trimmed = try builder.toOwnedSlice();
        defer allocator.free(trimmed);

        const size = std.mem.replace(u8, trimmed, " ", "", trimmed);
        value.* = try std.mem.Allocator.dupe(allocator, u8, trimmed[0 .. trimmed.len - size]);
    }
}

/// Represents the current host status info.
pub const Host = struct {
    pretty: []const u8 = "",
    name: []const u8 = "",
    id: []const u8 = "",
    version: []const u8 = "",
    versionFull: []const u8 = "",
    codename: []const u8 = "",
    hostname: []const u8 = "",
};

// ===================== Tests =====================

test "setValue parses NAME field with quotes" {
    const allocator = std.testing.allocator;
    var val: []const u8 = "";
    try setValue(allocator, []const u8, &val, "NAME=\"Ubuntu\"", "NAME=");
    try std.testing.expectEqualStrings("Ubuntu", val);
    allocator.free(val);
}

test "setValue parses ID field without quotes" {
    const allocator = std.testing.allocator;
    var val: []const u8 = "";
    try setValue(allocator, []const u8, &val, "ID=ubuntu", "ID=");
    try std.testing.expectEqualStrings("ubuntu", val);
    allocator.free(val);
}

test "setValue ignores non-matching line" {
    const allocator = std.testing.allocator;
    var val: []const u8 = "original";
    try setValue(allocator, []const u8, &val, "VERSION=\"22.04\"", "NAME=");
    try std.testing.expectEqualStrings("original", val);
}
