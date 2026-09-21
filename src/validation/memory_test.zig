const std = @import("std");
const root = @import("zero");

const httpz = root.httpz;
const Context = root.Context;
const utils = root.utils;

/// Byte-counting allocator used by the memory-validation harness (canonical
/// definition lives in `src/bench/alloc_count.zig` so the bench alloc-probe and
/// the test suite share one implementation).
pub const CountingAllocator = @import("../bench/alloc_count.zig").CountingAllocator;

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

// ===================== Tests =====================

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
