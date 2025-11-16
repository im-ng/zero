const std = @import("std");
const testing = std.testing;

/// Retrieves the current memory usage statistics.
///
/// This function reads the memory usage statistics from the `/proc/meminfo` file and returns a `MemUsage` struct containing the values.
///
/// Returns a `MemUsage` struct with the current memory usage statistics.
pub fn usage() !MemUsage {
    const file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    const contents = buffer[0..bytes_read];

    var lines = std.mem.splitSequence(u8, contents, "\n");
    var meminfo = MemUsage{};
    while (lines.next()) |line| {
        try setValue(&meminfo.total, line, "MemTotal:");
        try setValue(&meminfo.free, line, "MemFree:");
        try setValue(&meminfo.available, line, "MemAvailable:");
        try setValue(&meminfo.cached, line, "Cached:");
        try setValue(&meminfo.buffers, line, "Buffers:");
        try setValue(&meminfo.total_swap, line, "SwapTotal:");
        try setValue(&meminfo.free_swap, line, "SwapFree:");
    }

    return meminfo;
}

/// Sets the value of a field in the `MemUsage` struct.
///
/// - `value`: A pointer to the field to be set.
/// - `line`: The line of text containing the field value.
/// - `section`: The section of the line that contains the field name.
fn setValue(value: *usize, line: []const u8, section: []const u8) !void {
    if (std.mem.startsWith(u8, line, section)) {
        value.* = try std.fmt.parseInt(usize, std.mem.trim(u8, line[section.len..], " kB"), 10);
    }
}

/// Represents the current memory usage statistics.
const MemUsage = struct {
    /// The total amount of physical memory.
    total: usize = 0,
    /// The amount of free physical memory.
    free: usize = 0,
    /// The amount of memory available for new allocations.
    available: usize = 0,
    /// The amount of memory used for caching.
    cached: usize = 0,
    /// The amount of memory used for buffers.
    buffers: usize = 0,
    /// The total amount of swap space.
    total_swap: usize = 0,
    /// The amount of free swap space.
    free_swap: usize = 0,

    /// Calculates the percentage of memory used.
    ///
    /// Returns the percentage of memory used as a `f32` value, or an error if the memory usage statistics are not initialized.
    pub fn percentageUsed(self: MemUsage) !f32 {
        if (self.total == 0 or self.free == 0) {
            return error.MemUsageUninitialized;
        }
        const used_mem = self.total - self.free - self.buffers - self.cached;
        const used_ram_percentage = (@as(f32, @floatFromInt(used_mem)) / @as(f32, @floatFromInt(self.total))) * @as(f32, 100.0);
        return used_ram_percentage;
    }
};

test "memory" {
    const mem_usage = try usage();
    try testing.expect(mem_usage.total != 0);
    try testing.expect(mem_usage.free != 0);
    try testing.expect(mem_usage.available != 0);
    try testing.expect(mem_usage.cached != 0);
    try testing.expect(mem_usage.buffers != 0);
    try testing.expect(mem_usage.total_swap != 0);
    try testing.expect(mem_usage.free_swap != 0);
    try testing.expect(try mem_usage.percentageUsed() <= 100.0);

    // This is a badly initialization example
    const mem_usage2 = MemUsage{};
    try testing.expectError(error.MemUsageUninitialized, mem_usage2.percentageUsed());
}
