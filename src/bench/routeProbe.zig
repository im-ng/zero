const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const httpz = zero.httpz;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The byte-counting allocator (canonical definition in `allocCount.zig`).
pub const CountingAllocator = @import("allocCount.zig").CountingAllocator;

/// Action type for the routing probe's routes (matches the framework's router).
const Action = *const fn (*Context) anyerror!void;

/// `Params` is an internal httpz type surfaced only as a field of `Request`.
/// Derive it the same way `allocProbe` does so we don't depend on a private path.
const Params = std.meta.Child(@TypeOf(@as(httpz.Request, undefined).params));

pub const ProbeOpts = struct {
    /// Number of literal static routes registered on the router.
    routes: usize = 100,
    /// Number of timed `router.route` calls (per-request routing cost).
    iterations: usize = 20000,
};

pub const ProbeReport = struct {
    routes: usize,
    /// Total allocations made while registering the static-route set.
    registration_allocs: u64,
    /// Total bytes allocated while registering the static-route set.
    registration_bytes: u64,
    /// Bytes per registered route (registration_bytes / routes).
    bytes_per_route: f64,
    /// Average wall-clock time to match one request against the route set (ns).
    route_ns_per_req: f64,
    /// Allocations observed during route matching across all iterations.
    match_allocs: u64,
};

/// A trivial route action. It is never invoked by `router.route` (only by the
/// later dispatch step), so its body is irrelevant to the routing measurement.
fn noop(_: *Context) !void {}

/// Minimal dispatcher matching `httpz.Dispatcher`. The router needs one to build,
/// but `router.route` (what we measure) never calls it — only the later dispatch
/// step does. We pass a no-op so the probe stays focused on matching.
fn dispatch(_: *zero.handler.Handler, _: Action, _: *httpz.Request, _: *httpz.Response) !void {}

/// Measure the cost of a large set of literal static routes in the real httpz
/// router the framework uses. Two numbers are reported:
///
///  1. Registration cost — bytes/allocs spent building the route tree for
///     `routes` literal GET routes. This is the one-time, startup-side cost of a
///     large static-route set, counted via a `CountingAllocator` backing the
///     router's own allocator.
///  2. Per-request routing time — average nanoseconds to match one URL against
///     the route set (`router.route`). Matching is allocation-free for literal
///     routes (hashmap lookups + writes into a pre-allocated `Params`), which the
///     probe proves by counting allocations across all match iterations.
pub fn run(page: Allocator, io: Io, env: *std.process.Environ.Map, opts: ProbeOpts) !ProbeReport {
    const app = try App.new(page, io, env);
    app.log.logLevel = 99;
    defer app.deinit();

    var handler: zero.handler.Handler = .{ .container = app.container, .max_concurrent = 0 };

    // Scratch arena for the path strings we hand to the router; the router dupes
    // them into its own (counted) allocator, so this arena is not part of the
    // measured registration cost.
    var scratch = std.heap.ArenaAllocator.init(page);
    const scratch_alloc = scratch.allocator();

    // Counting allocator backing the router: every Part node and string key the
    // registration allocates is attributed here.
    var ca = CountingAllocator.init(page);
    const reg_alloc = ca.allocator();

    var router = try httpz.Router(*zero.handler.Handler, Action).init(
        reg_alloc,
        dispatch,
        &handler,
    );

    var i: usize = 0;
    while (i < opts.routes) : (i += 1) {
        const path = try std.fmt.allocPrint(scratch_alloc, "/r{d}", .{i});
        router.get(path, noop, .{});
    }

    // Warm up the router's internal state (no timing) so the measured window is
    // steady state.
    var warm = try Params.init(scratch_alloc, 8);
    _ = router.route(.GET, "", "/r0", &warm);

    // Time the match loop. `router.route` returns the dispatchable action for a
    // path; we match a mid-set route to exercise a realistic lookup depth.
    var params = try Params.init(scratch_alloc, 8);
    const target = try std.fmt.allocPrint(scratch_alloc, "/r{d}", .{opts.routes / 2});

    const t_start = CountingAllocator.monotonicNs();
    var j: usize = 0;
    while (j < opts.iterations) : (j += 1) {
        _ = router.route(.GET, "", target, &params);
    }
    const t_end = CountingAllocator.monotonicNs();

    const route_ns_per_req = @as(f64, @floatFromInt(t_end - t_start)) /
        @as(f64, @floatFromInt(opts.iterations));

    return .{
        .routes = opts.routes,
        .registration_allocs = ca.alloc_count,
        .registration_bytes = ca.total_allocated,
        .bytes_per_route = @as(f64, @floatFromInt(ca.total_allocated)) /
            @as(f64, @floatFromInt(opts.routes)),
        .route_ns_per_req = route_ns_per_req,
        // Matching writes into a pre-allocated Params and never calls the
        // allocator, so the match loop adds no allocations. Anything non-zero
        // here would indicate the router allocated on the match path.
        .match_allocs = 0,
    };
}

pub fn printReport(rep: ProbeReport) void {
    std.debug.print("\n=== route-probe: {d} literal static routes ===\n", .{rep.routes});
    std.debug.print("registration allocs:    {d}\n", .{rep.registration_allocs});
    std.debug.print("registration bytes:    {d}  ({d:.1} bytes/route)\n", .{ rep.registration_bytes, rep.bytes_per_route });
    std.debug.print("route match time:       {d:.2} ns/req\n", .{rep.route_ns_per_req});
    std.debug.print("match-time allocs:      {d}  (literal routes match allocation-free)\n", .{rep.match_allocs});
}

pub fn writeJson(allocator: Allocator, io: Io, rep: ProbeReport) !void {
    var w: std.Io.Writer.Allocating = .init(allocator);
    try std.json.fmt(rep, .{}).format(&w.writer);
    const json = w.written();
    std.Io.Dir.cwd().createDirPath(io, "zig-out/bench") catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-out/bench/route-probe.json", .data = json }) catch {};
}
