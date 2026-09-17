const std = @import("std");

/// A byte-counting allocator that wraps any backing allocator and records total
/// allocated / freed bytes plus a per-call-site breakdown.
///
/// It tracks the *true* allocation size per pointer (via a map), because some
/// helpers (e.g. utils.timestampz) alloc a buffer and return a truncated slice;
/// the real backing allocator frees the whole block by header, so counting freed
/// bytes by `buf.len` would under-count and false-positive a leak.
///
/// `free` is a no-op for pointers it never allocated (e.g. the stack-resident
/// `Context` that `Context.deinit` forwards to `allocator.destroy`), so the
/// counter can be dropped in as a request arena without crashing on the
/// framework's arena-style lifecycle. `reset` bulk-frees everything still live
/// (proving full reclaim after a request) while keeping aggregate counters.
pub const CountingAllocator = struct {
    pub const Live = struct { len: usize, alignment: std.mem.Alignment };
    pub const SiteStat = struct { count: u64, bytes: u64 };

    backing: std.mem.Allocator,
    sizes: std.AutoHashMap(usize, Live),
    by_site: std.AutoHashMap(usize, SiteStat),
    total_allocated: u64 = 0,
    total_freed: u64 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    high_water: u64 = 0,
    /// Summed time spent inside the backing allocator's `rawAlloc` (calibrated
    /// to subtract clock-read overhead). Measures request-path allocation cost.
    total_alloc_time_ns: u64 = 0,
    /// Measured cost of a `nowNs` round-trip; subtracted from each timed region.
    timer_overhead_ns: u64 = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return initBk(backing, backing);
    }

    /// Like `init`, but the allocator's own bookkeeping maps (`sizes`/`by_site`)
    /// are allocated on `bookkeeping` instead of `backing`. This matters when the
    /// measured `backing` is a transient arena that gets torn down before the
    /// report is read — the maps must outlive it.
    pub fn initBk(backing: std.mem.Allocator, bookkeeping: std.mem.Allocator) CountingAllocator {
        return .{
            .backing = backing,
            .sizes = std.AutoHashMap(usize, Live).init(bookkeeping),
            .by_site = std.AutoHashMap(usize, SiteStat).init(bookkeeping),
        };
    }

    /// Monotonic clock (CLOCK_MONOTONIC) in nanoseconds. `std.time.nanoTimestamp`
    /// was removed in 0.16, so we read it directly like the bench harness does.
    pub fn monotonicNs() u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    /// Measure the average `monotonicNs` round-trip cost so per-alloc timings can
    /// subtract it. Two reads per sample; the calibration sum already reflects a
    /// back-to-back pair, matching what `alloc` measures.
    pub fn calibrateTimer(self: *CountingAllocator) void {
        const n: u64 = 4000;
        var sum: u64 = 0;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const t0 = monotonicNs();
            const t1 = monotonicNs();
            sum += t1 - t0;
        }
        self.timer_overhead_ns = sum / n;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn key(ptr: [*]u8) usize {
        return @intFromPtr(ptr);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const t0 = monotonicNs();
        const res = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        const t1 = monotonicNs();
        const delta = t1 - t0;
        if (delta > self.timer_overhead_ns) {
            self.total_alloc_time_ns += delta - self.timer_overhead_ns;
        }
        self.sizes.put(key(res), .{ .len = len, .alignment = alignment }) catch {};
        self.total_allocated += len;
        self.alloc_count += 1;
        const out = self.total_allocated - self.total_freed;
        if (out > self.high_water) self.high_water = out;
        if (self.by_site.getPtr(ret_addr)) |s| {
            s.count += 1;
            s.bytes += len;
        } else {
            self.by_site.put(ret_addr, .{ .count = 1, .bytes = len }) catch {};
        }
        return res;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const old: Live = self.sizes.get(key(buf.ptr)) orelse .{ .len = buf.len, .alignment = alignment };
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            // backing freed `old` internally and allocated `new_len`.
            _ = self.sizes.remove(key(buf.ptr));
            self.sizes.put(key(buf.ptr), .{ .len = new_len, .alignment = alignment }) catch {};
            self.total_freed += old.len;
            self.total_allocated += new_len;
        }
        return ok;
    }

    fn free(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        // Not one of our tracked allocations (e.g. the stack-resident `Context`
        // that `Context.deinit` forwards to `allocator.destroy`): ignore it so
        // we never forward a stack pointer to the backing allocator.
        const live = self.sizes.get(key(buf.ptr)) orelse return;
        _ = self.sizes.remove(key(buf.ptr));
        self.backing.rawFree(buf, live.alignment, ret_addr);
        self.total_freed += live.len;
        self.free_count += 1;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        // Returning null tells the caller to fall back to alloc + copy + free,
        // which routes through our alloc/free counters (so accounting stays
        // correct). The validation paths never exercise remap.
        return null;
    }

    /// Bytes currently allocated and not yet freed.
    pub fn outstanding(self: *const CountingAllocator) u64 {
        return self.total_allocated - self.total_freed;
    }

    /// Bulk arena-style reset: frees every still-live allocation back to the
    /// backing allocator so a probe can prove full reclaim. Aggregated counters
    /// (alloc_count / total_allocated / by_site) are preserved so steady-state
    /// per-request costs can be measured across many iterations.
    pub fn reset(self: *CountingAllocator) void {
        var it = self.sizes.iterator();
        while (it.next()) |e| {
            const ptr = @as([*]u8, @ptrFromInt(e.key_ptr.*));
            self.backing.rawFree(ptr[0 .. e.value_ptr.*.len], e.value_ptr.*.alignment, @returnAddress());
            self.total_freed += e.value_ptr.*.len;
            self.free_count += 1;
        }
        self.sizes.clearRetainingCapacity();
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
