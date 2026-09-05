const std = @import("std");
const root = @import("zero");

const httpz = root.httpz;
const Context = root.Context;
const utils = root.utils;

/// A byte-counting allocator that wraps any backing allocator and records
/// total allocated / freed bytes. Used by the memory-validation harness to
/// prove whether allocations made under a zero.Context are released after a
/// request / cron tick / pubsub message.
///
/// It tracks the *true* allocation size per pointer (via a map), because some
/// helpers (e.g. utils.timestampz) alloc a buffer and return a truncated slice;
/// the real backing allocator frees the whole block by header, so counting freed
/// bytes by `buf.len` would under-count and false-positive a leak.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    sizes: std.AutoHashMap(usize, usize),
    total_allocated: u64 = 0,
    total_freed: u64 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    high_water: u64 = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{
            .backing = backing,
            .sizes = std.AutoHashMap(usize, usize).init(backing),
        };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn key(ptr: [*]u8) usize {
        return @intFromPtr(ptr);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const res = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.sizes.put(key(res), len) catch {};
        self.total_allocated += len;
        self.alloc_count += 1;
        const out = self.total_allocated - self.total_freed;
        if (out > self.high_water) self.high_water = out;
        return res;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const old = self.sizes.get(key(buf.ptr)) orelse buf.len;
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            // backing freed `old` internally and allocated `new_len`.
            _ = self.sizes.remove(key(buf.ptr));
            self.sizes.put(key(buf.ptr), new_len) catch {};
            self.total_freed += old;
            self.total_allocated += new_len;
        }
        return ok;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const original = self.sizes.get(key(buf.ptr)) orelse buf.len;
        _ = self.sizes.remove(key(buf.ptr));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.total_freed += original;
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

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

/// Minimal container whose optional backend fields are null so Context.init
/// takes no branch that dereferences a missing client. The allocator used here
/// is the counting allocator under test (so leaks from container.allocator are
/// observed), but otherwise the container is inert.
fn mockContainer(allocator: std.mem.Allocator) root.container {
    return root.container{
        .allocator = allocator,
        .appName = undefined,
        .appVersion = undefined,
        .log = undefined,
        .config = undefined,
        .metricz = undefined,
        .authProvider = undefined,
        .redis = null,
        .rdz = null,
        .SQL = null,
        .SQLite = null,
        .datasource = undefined,
        .services = null,
        .mqtt = null,
        .Kakfa = null,
        .Nats = null,
        .pubSub = null,
    };
}

// HTTP flow: Context.allocator is set to the per-request req.arena, which
// httpz resets (deinit) after every request. Allocations made during the
// request via ctx.allocator must therefore return to baseline.
test "http request context reclaims all allocations via req.arena" {
    var da = std.heap.DebugAllocator(.{}){};
    var ca = CountingAllocator.init(da.allocator());
    const alloc = ca.allocator();
    var c = mockContainer(alloc);
    var req: httpz.Request = undefined;
    var res: httpz.Response = undefined;

    const N: usize = 5000;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var req_arena = std.heap.ArenaAllocator.init(alloc);
        {
            var ctx = try Context.init(req_arena.allocator(), &c, &req, &res);
            // Simulate a handler that allocates through the context allocator,
            // including the formatting helper used for log lines.
            const buf = try ctx.allocator.alloc(u8, 100);
            _ = buf;
            const msg = try utils.combine(ctx.allocator, "request {d} handled", .{i});
            _ = msg;
        }
        req_arena.deinit();
    }

    try std.testing.expect(ca.outstanding() == 0);
}

// Cron flow: each job execution builds a fresh child ArenaAllocator
// (prepareChildAllocator) and destroys it after the job returns
// (destroryChildAllocator). Allocations via ctx.allocator must return to baseline.
test "cron job context reclaims all allocations via per-job child arena" {
    var da = std.heap.DebugAllocator(.{}){};
    var ca = CountingAllocator.init(da.allocator());
    const alloc = ca.allocator();
    var c = mockContainer(alloc);
    var req: httpz.Request = undefined;
    var res: httpz.Response = undefined;

    const N: usize = 5000;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var child = try alloc.create(std.heap.ArenaAllocator);
        child.* = std.heap.ArenaAllocator.init(alloc);
        {
            var ctx = try Context.init(child.allocator(), &c, &req, &res);
            const buf = try ctx.allocator.alloc(u8, 64);
            _ = buf;
            const msg = try utils.combine(ctx.allocator, "cron job {d} ran", .{i});
            _ = msg;
        }
        child.deinit();
        alloc.destroy(child);
    }

    try std.testing.expect(ca.outstanding() == 0);
}

// Pub/sub flow re-verification (after the fix). The per-message leak was the
// logger timestamp: utils.timestampz allocates and never frees, and the
// backends call the logger on the message path with the long-lived
// container.allocator. The applied fix adds `defer allocator.free(timestamp)`
// to the uppercase logger methods (Debug/Info/Any/Warn/Err/Fatal), and the
// backends now route message-path logging through log.Any(container.allocator, err).
// We exercise exactly that path and assert no net growth. A GeneralPurposeAllocator
// backs the counter so the one-time logger struct frees cleanly too.
test "pubsub message path reclaims per-message allocations (no surge)" {
    var da = std.heap.DebugAllocator(.{}){};
    const backing = da.allocator();
    var ca = CountingAllocator.init(backing);
    const alloc = ca.allocator();
    const log = try root.logger.create(alloc);

    const N: usize = 5000;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        // Mirrors the fixed per-message path: src/pubsub/* call
        // log.Any(container.allocator, err) -> timestampz free'd via defer.
        log.Any(alloc, error.ValidationFailed);
    }

    // Free the logger before measuring so only leaked (unfreed) bytes remain.
    log.deinit();

    try std.testing.expect(ca.outstanding() == 0);
}
