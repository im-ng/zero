const std = @import("std");
const root = @import("../zero.zig");
const Context = root.Context;

/// The path to the CPU information file.
const cpu_file = "/proc/cpuinfo";

/// The path to the CPU usage statistics file.
const stat_file = "/proc/stat";

/// The interval in nanoseconds between CPU usage updates.
const update_interval = 100 * std.time.ns_per_ms;

/// Represents the CPU information.
pub const CpuInfo = struct {
    /// The CPU vendor ID.
    vendor_id: []const u8 = "",
    /// The CPU family.
    cpu_family: []const u8 = "",
    /// The CPU model.
    model: []const u8 = "",
    /// The CPU model name.
    model_name: []const u8 = "",
    /// The CPU microcode.
    microcode: []const u8 = "",
    /// The CPU cache size.
    cache_size: []const u8 = "",
    /// The number of CPU cores.
    cpu_cores: []const u8 = "",
    ///
    cpu_speed: []const u8 = "",
};

/// Retrieves the CPU information.
///
/// Returns a `CpuInfo` struct containing the CPU information.
pub fn info(ctx: *Context) !CpuInfo {
    const file = try std.fs.openFileAbsolute("/proc/cpuinfo", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;

    const bytes_read = try file.readAll(&buffer);
    const contents = buffer[0..bytes_read];

    var cpuinfo = CpuInfo{};
    var lines = std.mem.splitSequence(u8, contents, "\n");
    while (lines.next()) |line| {
        try setValue(ctx.allocator, []const u8, &cpuinfo.vendor_id, line, "vendor_id");
        try setValue(ctx.allocator, []const u8, &cpuinfo.cpu_family, line, "cpu family");
        try setValue(ctx.allocator, []const u8, &cpuinfo.model, line, "model");
        try setValue(ctx.allocator, []const u8, &cpuinfo.model_name, line, "model name");
        try setValue(ctx.allocator, []const u8, &cpuinfo.microcode, line, "microcode");
        try setValue(ctx.allocator, []const u8, &cpuinfo.cache_size, line, "cache size");
        try setValue(ctx.allocator, []const u8, &cpuinfo.cpu_cores, line, "cpu cores");
        try setValue(ctx.allocator, []const u8, &cpuinfo.cpu_speed, line, "cpu MHz");
    }

    return cpuinfo;
}

/// Sets the value of a field in the `CpuInfo` struct.
///
/// - `allocator`: The memory allocator to use for dynamic memory allocation.
/// - `T`: The type of the field to set.
/// - `value`: A pointer to the field to be set.
/// - `line`: The line of text containing the field value.
/// - `section`: The section of the line that contains the field name.
fn setValue(allocator: std.mem.Allocator, comptime T: type, value: *T, line: []const u8, section: []const u8) !void {
    if (std.mem.startsWith(u8, line, section)) {
        const index = std.mem.indexOf(u8, line, ":").? + 2;
        value.* = switch (T) {
            u8, u16, u32 => try std.fmt.parseInt(T, line[index..], 10),
            f16, f32 => try std.fmt.parseFloat(T, line[index..]),
            else => try std.mem.Allocator.dupe(allocator, u8, line[index..]),
        };
    }
}

/// Calculates the percentage of CPU usage.
///
/// This function retrieves the CPU usage statistics twice, with a delay of `update_interval` nanoseconds between the two measurements.
/// It then calculates the percentage of CPU usage based on the difference between the two measurements.
///
/// Returns the percentage of CPU usage as a `f32` value.
pub fn percentageUsed() !f32 {
    const prev_stats = try usage();
    std.Thread.sleep(update_interval);
    const curr_stats = try usage();
    return calculateCpuUsage(prev_stats, curr_stats);
}

/// Retrieves the current CPU usage statistics.
///
/// This function reads the CPU usage statistics from the `/proc/stat` file and returns a `CpuUsage` struct containing the values.
///
/// Returns a `CpuUsage` struct with the current CPU usage statistics, or an error if the data is invalid.
pub fn usage() !CpuUsage {
    const file = try std.fs.openFileAbsolute(stat_file, .{});
    defer file.close();

    var buffer: [256]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const data = buffer[0..bytes_read];

    var lines = std.mem.splitSequence(u8, data, "\n");
    if (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "cpu")) {
            var parts = std.mem.splitSequence(u8, line[getFirstNumber(line)..], " ");
            return .{
                .user = try std.fmt.parseInt(u64, parts.next().?, 10),
                .nice = try std.fmt.parseInt(u64, parts.next().?, 10),
                .system = try std.fmt.parseInt(u64, parts.next().?, 10),
                .idle = try std.fmt.parseInt(u64, parts.next().?, 10),
                .iowait = try std.fmt.parseInt(u64, parts.next().?, 10),
            };
        }
    }
    return error.CpuUsageInvalidData;
}

/// Retrieves the index of the first number ocurrence.
///
/// This function reads a []const u8 and returns the index of the first number ocurrence.
/// Otherwise, returns 4 (taking "cpu " string as the default)
fn getFirstNumber(str: []const u8) usize {
    for (str, 0..) |char, i| {
        if (std.ascii.isDigit(char)) {
            return i;
        }
    }
    return 4;
}

/// Represents the CPU usage statistics.
const CpuUsage = struct {
    /// The time spent in user mode.
    user: u64,
    /// The time spent in user mode with low priority (nice).
    nice: u64,
    /// The time spent in system mode.
    system: u64,
    /// The time spent in the idle task.
    idle: u64,
    /// The time spent waiting for I/O to complete.
    iowait: u64,

    fn getTotal(self: CpuUsage) u64 {
        return self.user + self.nice + self.system + self.idle + self.iowait;
    }
};

/// Calculates the CPU usage percentage based on the provided CPU usage statistics.
///
/// - `prev_stats`: The CPU usage statistics for the previous measurement.
/// - `curr_stats`: The CPU usage statistics for the current measurement.
///
/// Returns the CPU usage percentage as a `f32` value.
fn calculateCpuUsage(prev: CpuUsage, curr: CpuUsage) f32 {
    const prev_idle = prev.idle;
    const curr_idle = curr.idle;

    const prev_total: u64 = prev.getTotal();
    const curr_total: u64 = curr.getTotal();

    const total_diff = curr_total - prev_total;
    const idle_diff = curr_idle - prev_idle;
    const res: f32 = (1.0 - (@as(f32, @floatFromInt(idle_diff)) / @as(f32, @floatFromInt(total_diff)))) * 100.0;
    return res;
}

test "cpu" {
    const testing = std.testing;
    const cpu_usage = try usage();
    try testing.expect(cpu_usage.getTotal() > 0);
    try testing.expect(@TypeOf(try percentageUsed()) == f32);

    const cpuinfo = try info();
    defer cpuinfo.deinit();
    try testing.expect(cpuinfo.vendor_id.len > 0);
    try testing.expect(cpuinfo.cpu_family > 0);
    try testing.expect(cpuinfo.model > 0);
    try testing.expect(cpuinfo.model_name.len > 0);
    try testing.expect(cpuinfo.microcode.len > 0);
    try testing.expect(cpuinfo.cache_size.len > 0);
    try testing.expect(cpuinfo.cpu_cores > 0);
}
