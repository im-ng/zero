const std = @import("std");
const testing = std.testing;

/// Retrieves the current process statistics.
///
/// This function reads the process usage statistics from the `/proc/process-id/status` file and returns a `ProcessStatus`
/// struct containing the values.
///
/// Returns a `ProcessStatus` struct with the current memory usage statistics.
pub fn usage(allocator: std.mem.Allocator, path: []const u8) !ProcessStatus {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    const contents = buffer[0..bytes_read];

    var lines = std.mem.splitSequence(u8, contents, "\n");
    var info = ProcessStatus{};
    while (lines.next()) |line| {
        try setValue(allocator, &info.vmHWM, line, "VmHWM:");
        try setValue(allocator, &info.vmRSS, line, "VmRSS:");
        try setValue(allocator, &info.rssAnon, line, "RssAnon:");
        try setValue(allocator, &info.rssFile, line, "RssFile:");
        try setValue(allocator, &info.threads, line, "Threads:");
    }

    return info;
}

/// Sets the value of a field in the `MemUsage` struct.
///
/// - `value`: A pointer to the field to be set.
/// - `line`: The line of text containing the field value.
/// - `section`: The section of the line that contains the field name.
fn setValue(allocator: std.mem.Allocator, value: *u64, line: []const u8, section: []const u8) !void {
    if (std.mem.startsWith(u8, line, section)) {
        const v = std.mem.trim(u8, line[section.len..], " kB");

        var builder = std.array_list.Managed(u8).init(allocator);
        defer builder.deinit();

        for (v) |char| {
            if (char == '\t') {
                continue;
            } else {
                try builder.append(char);
            }
        }
        const trimmed = try builder.toOwnedSlice();
        defer allocator.free(trimmed);

        _ = std.mem.replace(u8, trimmed, " ", "", trimmed);

        value.* = try std.fmt.parseInt(u64, trimmed, 10);
    }
}

/// Represents the current process status info.
pub const ProcessStatus = struct {
    threads: u64 = 0,
    rssAnon: u64 = 0,
    rssFile: u64 = 0,
    vmHWM: u64 = 0,
    vmRSS: u64 = 0,
};

test "setValue parses VmHWM line" {
    const allocator = std.testing.allocator;
    var val: u64 = 0;
    try setValue(allocator, &val, "VmHWM:    12345 kB", "VmHWM:");
    try std.testing.expect(val == 12345);
}

test "setValue parses Threads line" {
    const allocator = std.testing.allocator;
    var val: u64 = 0;
    try setValue(allocator, &val, "Threads:\t4", "Threads:");
    try std.testing.expect(val == 4);
}

test "setValue ignores non-matching line" {
    const allocator = std.testing.allocator;
    var val: u64 = 99;
    try setValue(allocator, &val, "VmRSS:     5000 kB", "VmHWM:");
    try std.testing.expect(val == 99);
}
