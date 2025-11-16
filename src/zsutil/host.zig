const std = @import("std");
const testing = std.testing;
const root = @import("../zero.zig");
const Context = root.Context;

/// Retrieves the current process statistics.
///
/// This function reads the process usage statistics from the `/proc/process-id/status` file and returns a `ProcessStatus`
/// struct containing the values.
///
/// Returns a `ProcessStatus` struct with the current memory usage statistics.
pub fn usage(ctx: *Context) !Host {
    const file = try std.fs.openFileAbsolute("/etc/os-release", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var bytes_read = try file.readAll(&buffer);
    var contents = buffer[0..bytes_read];

    var lines = std.mem.splitSequence(u8, contents, "\n");
    var host = Host{};
    while (lines.next()) |line| {
        try setValue(ctx.allocator, []const u8, &host.pretty, line, "PRETTY_NAME=");
        try setValue(ctx.allocator, []const u8, &host.name, line, "NAME=");
        try setValue(ctx.allocator, []const u8, &host.id, line, "ID=");
        try setValue(ctx.allocator, []const u8, &host.codename, line, "VERSION_CODENAME=");
        try setValue(ctx.allocator, []const u8, &host.version, line, "VERSION=");
        try setValue(ctx.allocator, []const u8, &host.versionFull, line, "DEBIAN_VERSION_FULL=");
    }

    const file2 = try std.fs.openFileAbsolute("/etc/hostname", .{});
    defer file2.close();

    buffer = undefined;
    bytes_read = try file2.readAll(&buffer);
    contents = buffer[0..bytes_read];

    try setValue(ctx.allocator, []const u8, &host.hostname, contents, "");

    return host;
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

        var trimmed: []u8 = undefined;
        trimmed = try allocator.alloc(u8, c.len);
        defer allocator.free(trimmed);

        for (c) |char| {
            if (char == '\n') {
                continue;
            } else if (char == '"') {
                continue;
            } else {
                try builder.append(char);
            }
        }
        trimmed = try builder.toOwnedSlice();

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
