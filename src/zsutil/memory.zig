const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const utils = @import("../utils.zig");
const root = @import("../zero.zig");

/// Read an integer sysctl value by name. Returns null when the OID is absent
/// or the value is not numeric; both are normal on non-Darwin systems.
fn sysctlInt(name: []const u8) ?usize {
    const result = std.process.run(
        std.heap.page_allocator,
        utils.io,
        .{ .argv = &.{ "/usr/sbin/sysctl", "-n", name } },
    ) catch return null;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const text = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(usize, text, 10) catch null;
}

/// Retrieves the current memory usage statistics.
/// Cross-platform: delegates to `zf.gather` so this works on macOS (sysctl) as
/// well as Linux (/proc/meminfo), instead of reading /proc directly. Reports
/// system-wide memory, not per-process.
/// Returns a `MemUsage` struct with the current memory usage statistics.
pub fn usage() !MemUsage {
    var sys = root.sysinfo.gather.gather(std.heap.page_allocator, utils.io);
    defer sys.deinit();

    var meminfo = MemUsage{};
    meminfo.total = sys.total_memory orelse 0;
    meminfo.free = sys.free_memory orelse 0;
    meminfo.available = meminfo.free;

    // zf's macOS gather only reads hw.memsize; it leaves free_memory null.
    // Fill it from the VM page counters so usage() is correct on macOS too.
    if (builtin.os.tag == .macos and meminfo.free == 0) {
        const pages = sysctlInt("vm.page_free_count") orelse 0;
        const page_size = sysctlInt("hw.pagesize") orelse 0;
        if (pages > 0 and page_size > 0) {
            meminfo.free = pages * page_size;
            meminfo.available = meminfo.free;
        }
    }

    return meminfo;
}

/// Sets the value of a field in the `MemUsage` struct.
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

// ===================== Tests =====================

test "memory" {
    const mem_usage = try usage();
    // Cross-platform: zf.gather reports total and free (available) system memory.
    // Per-process cached/buffers/swap detail is Linux-only and not provided here.
    try testing.expect(mem_usage.total != 0);
    try testing.expect(mem_usage.free != 0);
    try testing.expect(mem_usage.available != 0);
    try testing.expect(try mem_usage.percentageUsed() <= 100.0);

    const mem_usage2 = MemUsage{};
    try testing.expectError(error.MemUsageUninitialized, mem_usage2.percentageUsed());
}

test "MemUsage percentageUsed with known values" {
    const m = MemUsage{
        .total = 1000,
        .free = 400,
        .cached = 100,
        .buffers = 50,
    };
    const pct = try m.percentageUsed();
    try testing.expectApproxEqAbs(@as(f32, 45.0), pct, 0.01);
}

test "MemUsage percentageUsed zero total returns error" {
    const m = MemUsage{ .total = 0, .free = 100 };
    try testing.expectError(error.MemUsageUninitialized, m.percentageUsed());
}

test "setValue parses MemTotal line" {
    var val: usize = 0;
    try setValue(&val, "MemTotal:       16384000 kB", "MemTotal:");
    try testing.expectEqual(@as(usize, 16384000), val);
}

test "setValue parses MemFree line" {
    var val: usize = 0;
    try setValue(&val, "MemFree:          204800 kB", "MemFree:");
    try testing.expectEqual(@as(usize, 204800), val);
}

test "setValue ignores non-matching line" {
    var val: usize = 42;
    try setValue(&val, "SwapTotal:        4096000 kB", "MemTotal:");
    try testing.expectEqual(@as(usize, 42), val);
}
