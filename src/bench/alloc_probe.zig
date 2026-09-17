const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const httpz = zero.httpz;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The byte-counting allocator (canonical definition in `alloc_count.zig`). It
/// records per-call counts/bytes and attributes every allocation to its
/// call-site, so the probe can break the hot path down by source location.
pub const CountingAllocator = @import("alloc_count.zig").CountingAllocator;

/// Internal httpz types we need to hand-build a Request/Response without the
/// (test-only) `httpz.testing` harness. Pulled off the public Request/Response
/// field types so we don't depend on httpz's private module paths.
const HTTPConn = std.meta.Child(@TypeOf(@as(httpz.Request, undefined).conn));
const Params = std.meta.Child(@TypeOf(@as(httpz.Request, undefined).params));
const ReqAddress = @TypeOf(@as(httpz.Request, undefined).address);
const Protocol = @TypeOf(@as(httpz.Request, undefined).protocol);
const RespBuffer = @TypeOf(@as(httpz.Response, undefined).buffer);
const MultiFormKeyValue = std.meta.Child(@TypeOf(@as(httpz.Request, undefined).mfd));
const StringKeyValue = httpz.key_value.StringKeyValue;

pub const ProbeOpts = struct {
    /// Number of timed/measured requests driven through the handler.
    iterations: usize = 5000,
    /// Respond with `ctx.json(.{ .message = "pong" })` instead of a static body,
    /// so the probe also surfaces the JSON body-serialization cost.
    json_body: bool = false,
    /// Which allocator backs `req.arena` (approach b):
    ///  - heap:     page allocator — real heap/mmap, an upper bound on cost
    ///  - arena:    `std.heap.ArenaAllocator` — bump, like the production
    ///              per-connection arena (the FallbackAllocator's fallback)
    ///  - fallback: httpz's real `FallbackAllocator` (32 KB FBA -> Arena)
    backing: Backing = .heap,

    pub const Backing = enum { heap, arena, fallback };
};

/// Faithful copy of httpz's internal `FallbackAllocator` (httpz.zig:736): a 32 KB
/// `FixedBufferAllocator` that falls back to an `ArenaAllocator`. This is exactly
/// what production uses as the per-connection request arena, so the probe can
/// measure production-accurate (bump) allocation timing instead of the page
/// allocator's real-heap cost.
const FallbackAllocator = struct {
    fixed: Allocator,
    fallback: Allocator,
    fba: *std.heap.FixedBufferAllocator,

    pub fn init(fba: *std.heap.FixedBufferAllocator, fallback_alloc: Allocator) FallbackAllocator {
        return .{ .fixed = fba.allocator(), .fallback = fallback_alloc, .fba = fba };
    }

    pub fn allocator(self: *FallbackAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        return self.fixed.rawAlloc(len, alignment, ra) orelse self.fallback.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fba.ownsPtr(buf.ptr)) {
            return self.fixed.rawResize(buf, alignment, new_len, ra);
        }
        return self.fallback.rawResize(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fba.ownsPtr(buf.ptr)) {
            self.fixed.rawFree(buf, alignment, ra);
        }
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, new_len, ret_addr)) {
            return memory.ptr;
        }
        return null;
    }
};

/// One row of the per-call-site breakdown (averaged over all iterations).
pub const SiteLine = struct {
    name: []const u8,
    addr: usize,
    count: u64,
    bytes: u64,
};

pub const ProbeReport = struct {
    iterations: usize,
    allocs_per_req: f64,
    bytes_per_req: f64,
    leaked_bytes: u64,
    /// Total wall-clock time of the measured dispatch window, per request.
    latency_per_req_ns: f64,
    /// Time spent inside the backing allocator for request-path allocations,
    /// per request (calibrated; see `CountingAllocator`).
    alloc_time_per_req_ns: f64,
    /// `latency - alloc_time`: pure execution cost of dispatch (no allocation),
    /// i.e. the "dispatch logic only" number.
    dispatch_only_per_req_ns: f64,
    /// Which backing allocator was used (`heap` | `arena` | `fallback`).
    backing_kind: []const u8,
    json_body: bool,
    sites: []SiteLine,
};

fn pingStatic(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body = "pong";
}

fn pingJson(ctx: *Context) !void {
    try ctx.response.json(.{ .message = "pong" }, .{});
}

/// Minimal executor that runs the framework `Handler.dispatch` (the same method
/// the httpz middleware chain invokes for a real request) so the probe audits
/// the genuine request -> response hot path.
const Exec = struct {
    h: *zero.handler.Handler,
    action: *const fn (*Context) anyerror!void,
    req: *httpz.Request,
    res: *httpz.Response,
    pub fn next(self: @This()) !void {
        try self.h.dispatch(self.action, self.req, self.res);
    }
};

/// Known per-request allocation call-sites in this codebase, keyed by their
/// steady-state allocation size (bytes). Zig 0.16 dropped
/// `std.debug.getFunctionName`, so instead of resolving `ret_addr` at runtime we
/// label each site by its verified size. Sizes are stable for the current code;
/// if a site's size ever changes the hex `addr` (always emitted too) remains the
/// authoritative identifier.
const KnownSites = [_]struct { bytes: u64, label: []const u8 }{
    .{ .bytes = 36, .label = "tracz corr-id (mw/tracz.zig:24)" },
    .{ .bytes = 55, .label = "handler access-log (handler.zig:116, allocPrint)" },
    .{ .bytes = 88, .label = "SQL session (datasource/SQL.zig:58)" },
    .{ .bytes = 132, .label = "res.json body (httpz response)" },
};

fn labelForAlloc(per_req_bytes: u64) ?[]const u8 {
    for (KnownSites) |k| {
        if (k.bytes == per_req_bytes) return k.label;
    }
    return null;
}

fn resolveSite(allocator: Allocator, addr: usize, count: u64, bytes: u64, per_req_bytes: u64) SiteLine {
    const name = if (labelForAlloc(per_req_bytes)) |label|
        std.fmt.allocPrint(allocator, "{s} [0x{x}]", .{ label, addr }) catch label
    else
        std.fmt.allocPrint(allocator, "0x{x}", .{addr}) catch "unknown";
    return .{ .name = name, .addr = addr, .count = count, .bytes = bytes };
}

/// Allocate a fresh Request/Response pair whose `arena` points at `req_alloc`
/// (the counting allocator under test). The whole request — parsing structures
/// AND the framework hot path — is allocated on `req_alloc`, exactly as
/// production parses a connection's request onto its arena. `conn` is a
/// throwaway pointer: the framework never dereferences it during dispatch or
/// `res.json`/`body` (only `write*` does, which the probe never calls).
fn buildReqRes(req_alloc: Allocator) !struct { *httpz.Request, *httpz.Response } {
    // All scaffolding lives on `req_alloc` (the counting arena) so the request's
    // entire per-request memory — parsing structures AND the framework hot path —
    // is attributed to the same allocator. This is exactly how production behaves
    // (the whole request is parsed onto the connection's arena), and it makes
    // `latency - alloc_time` a clean "dispatch logic only" number.
    const conn = try req_alloc.create(HTTPConn);

    const url_buf = try req_alloc.dupe(u8, "/ping");
    const params = try req_alloc.create(Params);
    params.* = try Params.init(req_alloc, 8);
    const headers = try req_alloc.create(StringKeyValue);
    headers.* = try StringKeyValue.init(req_alloc, 64);
    const qs = try req_alloc.create(StringKeyValue);
    qs.* = try StringKeyValue.init(req_alloc, 64);
    const fd = try req_alloc.create(StringKeyValue);
    fd.* = try StringKeyValue.init(req_alloc, 64);
    const mfd = try req_alloc.create(MultiFormKeyValue);
    mfd.* = try MultiFormKeyValue.init(req_alloc, 64);
    const middlewares = try req_alloc.create(std.StringHashMap(*anyopaque));
    middlewares.* = std.StringHashMap(*anyopaque).init(req_alloc);

    const req: httpz.Request = .{
        .url = httpz.Url.parse(url_buf),
        .conn = conn,
        .address = undefined,
        .params = params,
        .headers = headers,
        .method = .GET,
        .method_string = "",
        .protocol = std.mem.zeroes(Protocol),
        .unread_body = 0,
        .qs = qs,
        .fd = fd,
        .mfd = mfd,
        .spare = &[_]u8{},
        .arena = req_alloc,
        .middlewares = middlewares,
        .route_data = null,
    };

    const res_headers = try StringKeyValue.init(req_alloc, 64);
    const res: httpz.Response = .{
        .conn = conn,
        .status = 200,
        .headers = res_headers,
        .content_type = null,
        .arena = req_alloc,
        .written = false,
        .chunked = false,
        .keepalive = false,
        .body = "",
        .buffer = RespBuffer.init(req_alloc),
        .pos = 0,
    };

    const rptr = try req_alloc.create(httpz.Request);
    rptr.* = req;
    const sptr = try req_alloc.create(httpz.Response);
    sptr.* = res;
    return .{ rptr, sptr };
}

/// Boots a real `zero.App` (no servers started), registers `GET /ping`, and
/// drives `iterations` requests through `Handler.dispatch` with a counting
/// allocator substituted for `req.arena`. Returns the per-request allocation
/// budget and a call-site breakdown.
///
/// Two refinements versus a naive loop:
///  - (a) the Request/Response scaffolding is allocated ON the counting arena
///    (not the general heap), so its cost is attributed and `latency -
///    alloc_time` is a clean "dispatch logic only" number.
///  - (b) `req.arena` can be backed by the real httpz `FallbackAllocator`
///    (32 KB FBA -> Arena) or a bare `ArenaAllocator`, to measure
///    production-accurate bump-allocation timing instead of page-heap cost.
pub fn run(page: Allocator, io: Io, env: *std.process.Environ.Map, opts: ProbeOpts) !ProbeReport {
    const app = try App.new(page, io, env);
    app.log.logLevel = 99;

    const action: *const fn (*Context) anyerror!void = if (opts.json_body) pingJson else pingStatic;
    var handler: zero.handler.Handler = .{ .container = app.container, .max_concurrent = 0 };

    // (b) selectable backing for req.arena.
    var arena_buf: [32 * 1024]u8 = undefined;
    var backing_arena = std.heap.ArenaAllocator.init(page);
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var fallback = FallbackAllocator.init(&fba, backing_arena.allocator());
    const backing: Allocator = switch (opts.backing) {
        .heap => page,
        .arena => backing_arena.allocator(),
        .fallback => fallback.allocator(),
    };

    // Warmup: amortize the one-time metric label-series allocation.
    {
        var ca = CountingAllocator.initBk(backing, page);
        const req_alloc = ca.allocator();
        var w: usize = 0;
        while (w < 200) : (w += 1) {
            const built = try buildReqRes(req_alloc);
            const t = try zero.tracz.init(.{ .allocator = req_alloc, .provider = &app.otelProvider });
            const exec = Exec{ .h = &handler, .action = action, .req = built[0], .res = built[1] };
            t.execute(built[0], built[1], exec) catch {};
        }
    }

    // Fresh counter for the measured window so the budget reflects steady state.
    // A fresh Request/Response is built each iteration (exactly as production
    // does); its scaffolding is allocated on the counting arena (approach a) so
    // the cost is attributed and `latency - alloc_time` is a clean dispatch-only
    // number.
    var ca = CountingAllocator.initBk(backing, page);
    ca.calibrateTimer();
    const req_alloc = ca.allocator();

    const t_start = CountingAllocator.monotonicNs();
    var i: usize = 0;
    while (i < opts.iterations) : (i += 1) {
        const built = try buildReqRes(req_alloc);
        const t = try zero.tracz.init(.{ .allocator = req_alloc, .provider = &app.otelProvider });
        const exec = Exec{ .h = &handler, .action = action, .req = built[0], .res = built[1] };
        t.execute(built[0], built[1], exec) catch {};
    }
    const t_end = CountingAllocator.monotonicNs();

    // Bulk-reclaim everything still live (proves the arena-equivalent reset
    // returns all per-request memory). Anything left outstanding is a leak.
    ca.reset();
    if (opts.backing != .heap) backing_arena.deinit();

    const latency_total_ns = t_end - t_start;
    const per_req_allocs = @as(f64, @floatFromInt(ca.alloc_count)) / @as(f64, @floatFromInt(opts.iterations));
    const per_req_bytes = @as(f64, @floatFromInt(ca.total_allocated)) / @as(f64, @floatFromInt(opts.iterations));
    const per_req_latency = @as(f64, @floatFromInt(latency_total_ns)) / @as(f64, @floatFromInt(opts.iterations));
    const per_req_alloc_time = @as(f64, @floatFromInt(ca.total_alloc_time_ns)) / @as(f64, @floatFromInt(opts.iterations));
    const per_req_dispatch_only = per_req_latency - per_req_alloc_time;

    var sites = std.array_list.Managed(SiteLine).init(page);
    var it = ca.by_site.iterator();
    while (it.next()) |e| {
        const site_per_req = e.value_ptr.*.bytes / opts.iterations;
        try sites.append(resolveSite(page, e.key_ptr.*, e.value_ptr.*.count, e.value_ptr.*.bytes, site_per_req));
    }
    std.mem.sort(SiteLine, sites.items, {}, struct {
        fn less(_: void, a: SiteLine, b: SiteLine) bool {
            return a.bytes > b.bytes;
        }
    }.less);

    return .{
        .iterations = opts.iterations,
        .allocs_per_req = per_req_allocs,
        .bytes_per_req = per_req_bytes,
        .leaked_bytes = ca.outstanding(),
        .latency_per_req_ns = per_req_latency,
        .alloc_time_per_req_ns = per_req_alloc_time,
        .dispatch_only_per_req_ns = per_req_dispatch_only,
        .backing_kind = @tagName(opts.backing),
        .json_body = opts.json_body,
        .sites = sites.toOwnedSlice() catch &.{},
    };
}

/// Human-readable report to stderr/stdout.
pub fn printReport(rep: ProbeReport) void {
    const body_kind = if (rep.json_body) "json body (ctx.json)" else "static body";
    std.debug.print("\n=== alloc-probe: GET /ping -> pong ({s}) [backing={s}] ===\n", .{ body_kind, rep.backing_kind });
    std.debug.print("iterations:            {d}\n", .{rep.iterations});
    std.debug.print("allocs / request:      {d:.2}\n", .{rep.allocs_per_req});
    std.debug.print("bytes  / request:      {d:.0}\n", .{rep.bytes_per_req});
    std.debug.print("latency / request:     {d:.1} ns ({d:.3} us)\n", .{ rep.latency_per_req_ns, rep.latency_per_req_ns / 1000.0 });
    std.debug.print("alloc time / request:  {d:.1} ns  (calibrated; backing={s})\n", .{ rep.alloc_time_per_req_ns, rep.backing_kind });
    std.debug.print("dispatch-only / req:   {d:.1} ns ({d:.3} us)  = latency - alloc time\n", .{ rep.dispatch_only_per_req_ns, rep.dispatch_only_per_req_ns / 1000.0 });
    std.debug.print("leaked after reset:    {d} bytes  ({s})\n", .{ rep.leaked_bytes, if (rep.leaked_bytes == 0) "OK" else "LEAK" });
    std.debug.print("\ncall-site breakdown (per request):\n", .{});
    std.debug.print("  {s:<48} {s:>5} {s:>8}\n", .{ "site", "count", "bytes" });
    for (rep.sites) |s| {
        const per = @as(f64, @floatFromInt(s.count)) / @as(f64, @floatFromInt(rep.iterations));
        std.debug.print("  {s:<48} {d:>5.2} {d:>8}\n", .{ s.name, per, s.bytes / rep.iterations });
    }
}

/// Machine-readable report (mirrors the bench report.json layout).
pub fn writeJson(allocator: Allocator, io: Io, rep: ProbeReport) !void {
    var w: std.Io.Writer.Allocating = .init(allocator);
    try std.json.fmt(rep, .{}).format(&w.writer);
    const json = w.written();
    std.Io.Dir.cwd().createDirPath(io, "zig-out/bench") catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-out/bench/alloc-probe.json", .data = json }) catch {};
}
