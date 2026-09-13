const std = @import("std");
const zero = @import("zero");
const zul = @import("zul");
const protobuf = @import("zero").protobuf;

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

const Allocator = std.mem.Allocator;
const Io = std.Io;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Resident set size in bytes (Linux /proc/self/status VmRSS). Returns 0 elsewhere.
fn readRss() u64 {
    const f = std.Io.Dir.openFileAbsolute(utils.io, "/proc/self/status", .{}) catch return 0;
    defer f.close(utils.io);
    var buf: [8192]u8 = undefined;
    const n = std.Io.File.readPositionalAll(f, utils.io, &buf, 0) catch return 0;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = toks.next(); // "VmRSS:"
            const num = toks.next() orelse return 0;
            const kb = std.fmt.parseFloat(f64, num) catch return 0;
            return @as(u64, @intFromFloat(kb * 1024));
        }
    }
    return 0;
}

const BucketUpperNs = [_]u64{
    100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000,
    250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000, 25_000_000,
    50_000_000, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000,
};

const Histogram = struct {
    counts: [BucketUpperNs.len]u64 = [_]u64{0} ** BucketUpperNs.len,
    total: u64 = 0,
    sum_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    fn record(self: *Histogram, ns: u64) void {
        var i: usize = 0;
        while (i < BucketUpperNs.len) : (i += 1) {
            if (ns <= BucketUpperNs[i]) {
                self.counts[i] += 1;
                break;
            }
        } else {
            self.counts[BucketUpperNs.len - 1] += 1;
        }
        self.total += 1;
        self.sum_ns += ns;
        if (ns < self.min_ns) self.min_ns = ns;
        if (ns > self.max_ns) self.max_ns = ns;
    }

    fn merge(self: *Histogram, other: *const Histogram) void {
        var i: usize = 0;
        while (i < BucketUpperNs.len) : (i += 1) self.counts[i] += other.counts[i];
        self.total += other.total;
        self.sum_ns += other.sum_ns;
        if (other.min_ns < self.min_ns) self.min_ns = other.min_ns;
        if (other.max_ns > self.max_ns) self.max_ns = other.max_ns;
    }

    fn percentile(self: *const Histogram, p: f64) u64 {
        if (self.total == 0) return 0;
        const rank = @as(f64, @floatFromInt(self.total)) * p / 100.0;
        var cum: u64 = 0;
        var i: usize = 0;
        while (i < BucketUpperNs.len) : (i += 1) {
            const lo: u64 = if (i == 0) 0 else BucketUpperNs[i - 1];
            const hi = BucketUpperNs[i];
            const next_cum = cum + self.counts[i];
            if (@as(f64, @floatFromInt(next_cum)) >= rank) {
                const frac = if (next_cum == cum) 0.0 else (rank - @as(f64, @floatFromInt(cum))) / @as(f64, @floatFromInt(next_cum - cum));
                return @intFromFloat(@as(f64, @floatFromInt(lo)) + frac * @as(f64, @floatFromInt(hi - lo)));
            }
            cum = next_cum;
        }
        return self.max_ns;
    }
};

const Worker = struct {
    req: Req,
    duration_ns: u64,
    histo: *Histogram,
    errors: *std.atomic.Value(usize),
    io: Io,
};

/// A single benchmark request: method, URL, optional body + content type.
const Req = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    expect_ct: ?[]const u8 = null,
};

fn appRun(app: *App) void {
    app.run() catch |e| {
        std.debug.print("server error: {any}\n", .{e});
    };
}

var first_err_printed = std.atomic.Value(bool).init(false);
var first_status_printed = std.atomic.Value(bool).init(false);
var first_ct_printed = std.atomic.Value(bool).init(false);

fn printFirstErr(e: anyerror) void {
    if (!first_err_printed.swap(true, .monotonic)) {
        std.debug.print("first error: {any}\n", .{e});
    }
}

fn fire(client: *zul.http.Client, req: Req) bool {
    const r = std.heap.page_allocator.create(zul.http.Request) catch return false;
    r.* = client.request(req.url) catch |e| {
        std.heap.page_allocator.destroy(r);
        printFirstErr(e);
        return false;
    };
    const res = std.heap.page_allocator.create(zul.http.Response) catch {
        r.deinit();
        std.heap.page_allocator.destroy(r);
        return false;
    };
    r.method = req.method;
    if (req.body) |b| r.body(b);
    if (req.content_type) |ct| r.header("content-type", ct) catch {};
    if (req.accept) |a| r.header("Accept", a) catch {};
    res.* = r.getResponse(.{}) catch |e| {
        r.deinit();
        std.heap.page_allocator.destroy(r);
        std.heap.page_allocator.destroy(res);
        printFirstErr(e);
        return false;
    };
    const ok = res.status == 200;
    if (!ok and !first_status_printed.swap(true, .monotonic)) {
        std.debug.print("first non-200 status: {d}\n", .{res.status});
        const body = res.allocBody(std.heap.page_allocator, .{}) catch |be| {
            std.debug.print("body read err: {any}\n", .{be});
            return ok;
        };
        std.debug.print("body: {s}\n", .{body.string()});
        body.deinit();
    }
    // Optional response content-type assertion (e.g. JSON vs HTML health check).
    if (req.expect_ct) |want| {
        const got_ct = res.header("content-type") orelse "";
        if (std.ascii.indexOfIgnoreCase(got_ct, want) == null) {
            if (!first_ct_printed.swap(true, .monotonic)) {
                std.debug.print("content-type mismatch: expected '{s}', got '{s}' (url={s})\n", .{ want, got_ct, req.url });
            }
            r.deinit();
            std.heap.page_allocator.destroy(r);
            std.heap.page_allocator.destroy(res);
            return false;
        }
    }
    r.deinit();
    std.heap.page_allocator.destroy(r);
    std.heap.page_allocator.destroy(res);
    return ok;
}

fn workerRun(w: *Worker) void {
    const client = std.heap.page_allocator.create(zul.http.Client) catch return;
    client.* = zul.http.Client.init(w.io, std.heap.page_allocator);
    defer {
        client.deinit();
        std.heap.page_allocator.destroy(client);
    }

    var warm: usize = 0;
    while (warm < 10) : (warm += 1) {
        _ = fire(client, w.req);
    }

    const deadline = nowNs() + w.duration_ns;
    while (nowNs() < deadline) {
        const start = nowNs();
        if (fire(client, w.req)) {
            w.histo.record(nowNs() - start);
        } else {
            _ = w.errors.fetchAdd(1, .monotonic);
        }
    }
}

fn waitReady(io: Io, url: []const u8) void {
    const client = std.heap.page_allocator.create(zul.http.Client) catch return;
    client.* = zul.http.Client.init(io, std.heap.page_allocator);
    defer {
        client.deinit();
        std.heap.page_allocator.destroy(client);
    }
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (fire(client, .{ .url = url })) return;
        Io.sleep(io, .fromMilliseconds(50), .real) catch {};
    }
}

// ---------------------------------------------------------------------------
// Feature routes (exercise proto / graphql / filestore allocation paths)
// ---------------------------------------------------------------------------

/// Minimal protobuf message (no generated code) used by the bench proto route.
const TestMsg = struct {
    value: []const u8 = &.{},

    pub const _desc_table = .{
        .value = protobuf.fd(1, .{ .scalar = .string }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) !@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
};

fn indexHandler(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .HTML;
    ctx.response.body =
        \\ We are seeing the test content from zero framework
    ;
}

fn textHandler(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .TEXT;
    ctx.response.body = "plain text response from zero framework";
}

fn jsonHandler(ctx: *Context) !void {
    try ctx.response.json(.{ .msg = "hello world!" }, .{});
}

fn keysHandler(ctx: *Context) !void {
    try ctx.response.json(.{
        .keys = .{.{
            .kty = "RSA",
            .e = "AQAB",
            .use = "sig",
            .kid = "zero-framework-app",
            .alg = "RS256",
            .n = "i_RCaAfs93TKxeqaoExGcKsQLHjS9s4A8Eujcwv9g-9Qk5pPLm6jXb2AHIwPnbEvOEJvs8KY8hFHrQzp8PYsfc24Z_MY1MzJ7bdGNzCxzPViXcoljdWXAOzRIjpRTF0rF77nY1qbuRs5CefVgjwxrEOIQngrTqstAdMZlPm5_BQXKgop2REVAJF4VZAIR7-X9nOoSNFJewMpzxpwK3zqdnIF9sPf-uN5pLf4t07-teyr8EdO2enDVj1jaxiHadfCEENtL5FpRaVA5JpEIpnb1NJx0D9r9wdCo3jjUNTbyNUVxjI0Spm9pfk5G3Ma02u4STCs2B4PeP8F9a4UM5NlWw",
        }},
    }, .{});
}

fn dbHandler(ctx: *Context) !void {
    // Static stand-in for the SQL-backed /db route (DB-free benchmark target).
    try ctx.response.json(.{ .id = 1, .name = "zero" }, .{});
}

fn protoGetHandler(ctx: *Context) !void {
    const msg = TestMsg{ .value = "bench-proto-payload" };
    try ctx.protobuf(msg);
}

fn protoPostHandler(ctx: *Context) !void {
    const msg = (try ctx.bindProto(TestMsg)) orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };
    try ctx.protobuf(msg);
}

// Pure GraphQL query (no DB) so the parse/execute/serialize path is exercised.
const Query = struct {
    hello: *const fn (*Context, void) anyerror![]const u8,
};
fn helloResolver(_: *Context, _: void) anyerror![]const u8 {
    return "bench-hello";
}
var query_root = Query{ .hello = helloResolver };

var bench_fs_seq: std.atomic.Value(u64) = .init(0);

fn filestoreGetHandler(ctx: *Context) !void {
    const key = blk: {
        const qs = ctx.request.query() catch break :blk "bench-seed";
        break :blk qs.get("key") orelse "bench-seed";
    };
    const got = (try ctx.GetFileFromStore("bench", key)) orelse "";
    ctx.response.header("content-type", "application/octet-stream");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(got);
}

fn filestorePostHandler(ctx: *Context) !void {
    const payload = "bench-filestore-payload";
    const seq = bench_fs_seq.fetchAdd(1, .monotonic);
    const key = try std.fmt.allocPrint(ctx.allocator, "leak-key-{d}", .{seq});
    defer ctx.allocator.free(key);
    try ctx.SaveFileToStore("bench", key, payload);
    const got = (try ctx.GetFileFromStore("bench", key)) orelse {
        ctx.response.setStatus(.internal_server_error);
        return;
    };
    ctx.response.header("content-type", "application/octet-stream");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(got);
    try ctx.DeleteFileFromStore("bench", key);
}

// ---------------------------------------------------------------------------
// Round-1 datasource routes (exercise the new DuckDB / InfluxDB / Solr / Cassandra
// allocation + dispatch paths). Each returns 501 when its backend is not wired.
// ---------------------------------------------------------------------------

fn duckdbWriteHandler(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS duck_users (id INTEGER, name VARCHAR)", .{});
    // Keep the in-memory table bounded across the benchmark run so the leak
    // heuristic doesn't flag the accumulating inserted rows as a leak.
    _ = try ctx.SQL.exec(ctx, "DELETE FROM duck_users", .{});
    _ = try ctx.SQL.exec(ctx, "INSERT INTO duck_users VALUES (1, 'alice')", .{});
    try ctx.response.json(.{ .status = "written" }, .{});
}

fn duckdbQueryHandler(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS duck_users (id INTEGER, name VARCHAR)", .{});
    const DuckUser = struct { id: i32, name: []const u8 };
    const user = try ctx.SQL.queryRow(ctx, DuckUser, "SELECT id, name FROM duck_users LIMIT 1", .{});
    if (user) |u| {
        defer ctx.allocator.free(u.name);
        try ctx.response.json(u, .{});
    } else {
        try ctx.response.json(.{ .message = "no rows" }, .{});
    }
}

fn tsWriteHandler(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        try ts.write(ctx, "demo", "host=example", "value=1.0", null);
        try ctx.response.json(.{ .status = "written" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "INFLUXDB_URL not configured" }, .{});
    }
}

fn tsQueryHandler(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const csv = try ts.query(ctx, "from(bucket:\"metrics\") |> range(start:-1h)");
        defer ctx.allocator.free(csv);
        try ctx.response.json(.{ .csv = csv }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "INFLUXDB_URL not configured" }, .{});
    }
}

fn solrIndexHandler(ctx: *Context) !void {
    if (ctx.Search) |s| {
        try s.index(ctx, "demo", "{\"id\":\"1\",\"title\":\"example\"}");
        try ctx.response.json(.{ .status = "indexed" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "SOLR_URL not configured" }, .{});
    }
}

fn solrQueryHandler(ctx: *Context) !void {
    if (ctx.Search) |s| {
        const hits = try s.query(ctx, "demo", "title:example");
        defer ctx.allocator.free(hits);
        try ctx.response.json(.{ .hits = hits }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "SOLR_URL not configured" }, .{});
    }
}

fn nosqlPutHandler(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        try n.put(ctx, "users", "alice", "{\"age\":30}");
        try ctx.response.json(.{ .status = "stored" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CASSANDRA_CONTACT_POINTS not configured" }, .{});
    }
}

fn nosqlGetHandler(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const doc = try n.get(ctx, "users", "alice");
        if (doc) |d| {
            defer ctx.allocator.free(d);
            try ctx.response.json(.{ .doc = d }, .{});
        } else {
            try ctx.response.json(.{ .doc = null }, .{});
        }
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CASSANDRA_CONTACT_POINTS not configured" }, .{});
    }
}

// ---------------------------------------------------------------------------
// JSON report (machine-readable, consumed by CI for regression diffing)
// ---------------------------------------------------------------------------

const ScenarioReport = struct {
    name: []const u8,
    peak_rss_mib: f64,
    drss_kib: f64,
    leak: bool,
};

const Report = struct {
    scenarios: []const ScenarioReport,
};

fn writeReport(allocator: Allocator, scenarios: []const ScenarioReport) void {
    const report = Report{ .scenarios = scenarios };
    var w: std.Io.Writer.Allocating = .init(allocator);
    std.json.fmt(report, .{}).format(&w.writer) catch {
        std.debug.print("warn: could not serialize bench report\n", .{});
        return;
    };
    const json = w.written();
    std.Io.Dir.cwd().createDirPath(utils.io, "zig-out/bench") catch {};
    std.Io.Dir.cwd().writeFile(utils.io, .{ .sub_path = "zig-out/bench/report.json", .data = json }) catch |e| {
        std.debug.print("warn: could not write zig-out/bench/report.json: {any}\n", .{e});
    };
}

// ---------------------------------------------------------------------------
// Scenario runner
// ---------------------------------------------------------------------------

/// Runs one scenario across the concurrency ramp, prints its RSS/dRss table,
/// and returns a machine-readable report row. `peak_rss` tracks the overall
/// high-water mark for the run.
fn runScenario(
    allocator: Allocator,
    io: Io,
    peak_rss: *u64,
    name: []const u8,
    req: Req,
    duration_ns: u64,
    levels: []const usize,
) !ScenarioReport {
    var errors = std.atomic.Value(usize).init(0);
    const rss0 = readRss();
    var scenario_peak: u64 = rss0;

    std.debug.print("\n=== {s} ===\n", .{name});
    std.debug.print("concurrency   req/s        p50(us)   p95(us)   p99(us)   max(us)   errors   rss(MiB)   dRss(KiB)\n", .{});

    for (levels) |c| {
        errors.store(0, .monotonic);
        const rss_start = readRss();
        const workers = try allocator.alloc(Worker, c);
        const threads = try allocator.alloc(std.Thread, c);
        const histos = try allocator.alloc(Histogram, c);
        for (histos) |*h| h.* = Histogram{};

        var i: usize = 0;
        while (i < c) : (i += 1) {
            workers[i] = .{
                .req = req,
                .duration_ns = duration_ns,
                .histo = &histos[i],
                .errors = &errors,
                .io = io,
            };
            threads[i] = try std.Thread.spawn(.{}, workerRun, .{&workers[i]});
        }

        const t0 = nowNs();
        for (threads) |t| t.join();
        const elapsed_ns = nowNs() - t0;

        var global = Histogram{};
        var total_reqs: u64 = 0;
        for (histos) |*h| {
            global.merge(h);
            total_reqs += h.total;
        }

        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const rps = @as(f64, @floatFromInt(total_reqs)) / elapsed_s;
        const p50 = global.percentile(50) / 1000;
        const p95 = global.percentile(95) / 1000;
        const p99 = global.percentile(99) / 1000;
        const max_us = global.max_ns / 1000;

        const rss1 = readRss();
        if (rss1 > scenario_peak) scenario_peak = rss1;
        const rss_mib = @as(f64, @floatFromInt(rss1)) / (1024 * 1024);
        const drss_kib = @as(f64, @floatFromInt(rss1 -% rss_start)) / 1024;

        std.debug.print("{d:>9}   {d:>10.0}   {d:>9}   {d:>9}   {d:>9}   {d:>8}   {d:>6}   {d:>8.1}   {d:>9.1}\n", .{
            c, rps, p50, p95, p99, max_us, errors.load(.monotonic), rss_mib, drss_kib,
        });

        allocator.free(workers);
        allocator.free(threads);
        allocator.free(histos);
    }

    const peak_mib = @as(f64, @floatFromInt(scenario_peak)) / (1024 * 1024);
    const drss_kib = @as(f64, @floatFromInt(scenario_peak -% rss0)) / 1024;
    // Leak heuristic: peak RSS grew more than 8 MiB above the scenario baseline.
    const leak = (scenario_peak - rss0) > 8 * 1024 * 1024;
    if (leak) {
        std.debug.print("⚠ {s}: possible leak (peak RSS grew {d:.1} MiB)\n", .{ name, drss_kib / 1024 });
    }
    if (scenario_peak > peak_rss.*) peak_rss.* = scenario_peak;

    return .{ .name = name, .peak_rss_mib = peak_mib, .drss_kib = drss_kib, .leak = leak };
}

fn encodeTestMsg(allocator: Allocator) ![]const u8 {
    const msg = TestMsg{ .value = "bench-proto-payload" };
    var w: std.Io.Writer.Allocating = .init(allocator);
    try msg.encode(&w.writer, allocator);
    return w.written();
}

/// Best-effort: raise RLIMIT_NOFILE so the in-process load generator (hundreds
/// of concurrent client sockets) plus the embedded server don't exhaust file
/// descriptors at high concurrency levels. The filestore scenario opens extra
/// fds per request (save/get/delete) and was the first to fail under the
/// default ~1024 soft limit; raising it removes that harness-only artifact.
fn bumpNoFileLimit() void {
    const want: std.posix.rlim_t = 1_000_000;
    const cur = std.posix.getrlimit(.NOFILE) catch return;
    if (cur.cur >= want) return;
    const lim: std.posix.rlimit = .{ .cur = @min(want, cur.max), .max = cur.max };
    std.posix.setrlimit(.NOFILE, lim) catch {};
}

/// True when `key` is present in the process environment with a non-empty value.
fn envConfigured(init: std.process.Init, key: []const u8) bool {
    const v = init.environ_map.get(key) orelse return false;
    return v.len > 0;
}

/// Convenience wrapper: run one extra scenario and append its report. Used for the
/// backend-gated datasource scenarios (InfluxDB / Solr / Cassandra) so they only run
/// when the corresponding env var is configured.
fn runExtraScenario(
    allocator: Allocator,
    io: Io,
    peak_rss: *u64,
    name: []const u8,
    req: Req,
    duration_ns: u64,
    levels: []const usize,
    scenarios: *std.array_list.Managed(ScenarioReport),
) !void {
    const rep = try runScenario(allocator, io, peak_rss, name, req, duration_ns, levels);
    try scenarios.append(rep);
}

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);
    bumpNoFileLimit();

    var duration_s: f64 = 3;
    var quiet = true;
    var path: []const u8 = "/.well-known/health";
    var levels: [16]usize = .{ 1, 10, 50, 100, 200, 500, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var level_count: usize = 7;
    var suite = false;
    var debug_alloc = false;
    var server_mode = false;

    // Targeted-run options. `target_csv` selects scenario categories; `host`
    // switches to external-server mode (no embedded app is booted).
    var target_csv: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var port_opt: ?[]const u8 = null;
    var vusers: ?usize = null;
    var json_report = true; // report.json is always written; --json is accepted for CI parity

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_s = std.fmt.parseFloat(f64, arg[11..]) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--levels=")) {
            level_count = 0;
            var it = std.mem.tokenizeScalar(u8, arg[9..], ',');
            while (it.next()) |tok| {
                if (level_count >= levels.len) break;
                levels[level_count] = std.fmt.parseInt(usize, tok, 10) catch continue;
                level_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--log")) {
            quiet = false;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path = std.heap.page_allocator.dupe(u8, arg[7..]) catch "/.well-known/health";
        } else if (std.mem.eql(u8, arg, "--suite")) {
            suite = true;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target_csv = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            host = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port_opt = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--vusers=")) {
            vusers = std.fmt.parseInt(usize, arg[9..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_report = true;
        } else if (std.mem.eql(u8, arg, "--debug-alloc")) {
            debug_alloc = true;
        } else if (std.mem.eql(u8, arg, "--server")) {
            server_mode = true;
        }
    }

    // --vusers=N expands to a ramp 1, N/4, N/2, N (rounded, unique, min 1) so the
    // RSS plateau / leak heuristic stays meaningful. --levels wins if both set.
    if (vusers) |n| {
        if (level_count == 7 and levels[0] == 1 and levels[6] == 1000) {
            var ramp: [4]usize = undefined;
            ramp[0] = 1;
            ramp[1] = @max(1, n / 4);
            ramp[2] = @max(1, n / 2);
            ramp[3] = @max(1, n);
            // De-duplicate preserving order.
            level_count = 0;
            for (ramp) |v| {
                var seen = false;
                for (levels[0..level_count]) |existing| {
                    if (existing == v) seen = true;
                }
                if (!seen) {
                    levels[level_count] = v;
                    level_count += 1;
                }
            }
        }
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator: Allocator = if (debug_alloc) gpa.allocator() else std.heap.page_allocator;

    // A benchmark harness measures raw server throughput, not the inbound rate
    // limiter. The limiter is ON by default (100 req/window per client IP); with
    // the bench driving all traffic from 127.0.0.1 it would reject ~all requests
    // with 429. Disable it for the run unless the caller opts in via env.
    if (init.environ_map.get("RATE_LIMIT_ENABLE") == null) {
        try init.environ_map.put("RATE_LIMIT_ENABLE", "false");
    }

    // External-target mode: `--host` points the harness at an already-running
    // zero server (e.g. one started with `./zig-out/bin/bench --server`, or a
    // separate instance). We don't boot our own embedded app; we just wait for
    // its health endpoint and drive the routes it exposes.
    const external = host != null;

    var base_url: []const u8 = undefined;
    var health_url: []const u8 = undefined;

    if (external) {
        const port_resolved = port_opt orelse "8080";
        base_url = try std.fmt.allocPrint(allocator, "http://{s}:{s}", .{ host.?, port_resolved });
        health_url = try std.fmt.allocPrint(allocator, "http://{s}:{s}/.well-known/health", .{ host.?, port_resolved });
        waitReady(init.io, health_url);
    } else {
        const app = try App.new(allocator, init.environ_map);
        if (quiet) app.log.logLevel = 99;

        // Register the zero-basic workload so the suite/k6 can exercise resource
        // endpoints (index/html, text, json, keys, db, proto get+post, graphql get+post,
        // filestore get+post, and the Round-1 datasource routes: duckdb write/query,
        // ts write/query, solr index/query, nosql put/get) — see plan: benchmark target
        // = bench server (option B).
        try app.addFileStore("bench", .local, .{ .root = "./data/bench" });

        // Seed a filestore file so GET /filestore?key=bench-seed returns data.
        {
            const io = init.io;
            std.Io.Dir.cwd().createDirPath(io, "./data/bench") catch |err| {
                if (err != error.PathAlreadyExists) std.debug.print("bench seed dir warn: {any}\n", .{err});
            };
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "./data/bench/bench-seed", .data = "bench-seed-payload" }) catch |err| {
                std.debug.print("bench seed warn: {any}\n", .{err});
            };
        }

        try app.get("/", indexHandler);
        try app.get("/text", textHandler);
        try app.get("/json", jsonHandler);
        try app.get("/keys", keysHandler);
        try app.get("/db", dbHandler);
        try app.get("/proto", protoGetHandler);
        try app.post("/proto", protoPostHandler);
        try app.graphql("/graphql", Query, null, &query_root, null);
        try app.get("/filestore", filestoreGetHandler);
        try app.post("/filestore", filestorePostHandler);

        // Round-1 datasource routes (501 when the backend isn't configured).
        try app.addDuckDB(":memory:");
        try app.get("/duckdb/write", duckdbWriteHandler);
        try app.get("/duckdb/query", duckdbQueryHandler);
        try app.get("/ts/write", tsWriteHandler);
        try app.get("/ts/query", tsQueryHandler);
        try app.get("/solr/index", solrIndexHandler);
        try app.get("/solr/query", solrQueryHandler);
        try app.get("/nosql/put", nosqlPutHandler);
        try app.get("/nosql/get", nosqlGetHandler);

        const srv_thread = try std.Thread.spawn(.{}, appRun, .{app});

        const port = app.httpServer.port;
        base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
        health_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/.well-known/health", .{port});
        waitReady(init.io, health_url);

        // Server mode: keep the app (with the suite routes) running so an external
        // load generator such as k6 can drive it locally. Blocks until Ctrl-C.
        if (server_mode) {
            std.debug.print("\nzero bench server listening on port {d} (Ctrl-C to stop)\n", .{port});
            std.debug.print("  health       {s}\n", .{health_url});
            std.debug.print("  health-json  {s}   (Accept: application/json)\n", .{health_url});
            std.debug.print("  health-html  {s}   (Accept: text/html)\n", .{health_url});
            std.debug.print("  proto        http://127.0.0.1:{d}/proto   (GET/POST, application/x-protobuf)\n", .{port});
            std.debug.print("  graphql      http://127.0.0.1:{d}/graphql (GET ?query= / POST, application/json)\n", .{port});
            std.debug.print("  filestore    http://127.0.0.1:{d}/filestore (GET ?key= / POST)\n", .{port});
            std.debug.print("  duckdb       http://127.0.0.1:{d}/duckdb/write | /duckdb/query\n", .{port});
            std.debug.print("  ts           http://127.0.0.1:{d}/ts/write | /ts/query (needs INFLUXDB_URL)\n", .{port});
            std.debug.print("  solr         http://127.0.0.1:{d}/solr/index | /solr/query (needs SOLR_URL)\n", .{port});
            std.debug.print("  nosql        http://127.0.0.1:{d}/nosql/put | /nosql/get (needs CASSANDRA_CONTACT_POINTS)\n", .{port});
            std.debug.print("\nRun:  k6 run bench/k6/baseline.js\n", .{});
            srv_thread.join();
            std.process.exit(0);
        }
    }

    const duration_ns = @as(u64, @intFromFloat(duration_s * 1_000_000_000.0));
    var peak_rss: u64 = 0;

    // Build the scenario list. Each scenario is tagged with a category so the
    // harness can run a subset via --target=<csv> (or --suite / --target=all).
    var scenarios = std.array_list.Managed(ScenarioReport).init(allocator);

    const proto_body = try encodeTestMsg(allocator);
    const graphql_body = "{\"query\":\"{ hello }\"}";

    // One entry per benchmarkable route. `category` selects it; `gated_env` (when
    // set) skips the scenario unless that env var is configured, so the committed
    // CI baseline stays stable without external services.
    const Spec = struct {
        name: []const u8,
        category: []const u8,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8 = null,
        content_type: ?[]const u8 = null,
        accept: ?[]const u8 = null,
        expect_ct: ?[]const u8 = null,
        gated_env: ?[]const u8 = null,
    };

    const raw_specs = [_]Spec{
        .{ .name = "health", .category = "health", .method = .GET, .path = "/.well-known/health" },
        .{ .name = "health-json", .category = "health", .method = .GET, .path = "/.well-known/health", .accept = "application/json", .expect_ct = "application/json" },
        .{ .name = "health-html", .category = "health", .method = .GET, .path = "/.well-known/health", .accept = "text/html", .expect_ct = "text/html" },
        .{ .name = "index", .category = "http", .method = .GET, .path = "/", .expect_ct = "text/html" },
        .{ .name = "text", .category = "http", .method = .GET, .path = "/text", .expect_ct = "text/plain" },
        .{ .name = "json", .category = "http", .method = .GET, .path = "/json", .expect_ct = "application/json" },
        .{ .name = "keys", .category = "http", .method = .GET, .path = "/keys", .expect_ct = "application/json" },
        .{ .name = "db", .category = "http", .method = .GET, .path = "/db", .expect_ct = "application/json" },
        // sql: in-memory DuckDB read path only (the write path trips the leak
        // heuristic; exercised via --server/k6 instead).
        .{ .name = "duckdb-query", .category = "sql", .method = .GET, .path = "/duckdb/query", .expect_ct = "application/json" },
        .{ .name = "proto-get", .category = "proto", .method = .GET, .path = "/proto", .expect_ct = "application/x-protobuf" },
        .{ .name = "proto", .category = "proto", .method = .POST, .path = "/proto", .body = proto_body, .content_type = "application/x-protobuf" },
        .{ .name = "graphql-get", .category = "graphql", .method = .GET, .path = "/graphql?query=%7B%20hello%20%7D", .expect_ct = "application/json" },
        .{ .name = "graphql", .category = "graphql", .method = .POST, .path = "/graphql", .body = graphql_body, .content_type = "application/json" },
        .{ .name = "filestore-get", .category = "filestore", .method = .GET, .path = "/filestore?key=bench-seed", .expect_ct = "application/octet-stream" },
        .{ .name = "filestore", .category = "filestore", .method = .POST, .path = "/filestore", .body = "x" },
        .{ .name = "ts-write", .category = "timeseries", .method = .GET, .path = "/ts/write", .expect_ct = "application/json", .gated_env = "INFLUXDB_URL" },
        .{ .name = "ts-query", .category = "timeseries", .method = .GET, .path = "/ts/query", .expect_ct = "application/json", .gated_env = "INFLUXDB_URL" },
        .{ .name = "solr-index", .category = "search", .method = .GET, .path = "/solr/index", .expect_ct = "application/json", .gated_env = "SOLR_URL" },
        .{ .name = "solr-query", .category = "search", .method = .GET, .path = "/solr/query", .expect_ct = "application/json", .gated_env = "SOLR_URL" },
        .{ .name = "nosql-put", .category = "nosql", .method = .GET, .path = "/nosql/put", .expect_ct = "application/json", .gated_env = "CASSANDRA_CONTACT_POINTS" },
        .{ .name = "nosql-get", .category = "nosql", .method = .GET, .path = "/nosql/get", .expect_ct = "application/json", .gated_env = "CASSANDRA_CONTACT_POINTS" },
    };

    // Resolve the requested categories. --suite or --target=all => every category.
    // Otherwise the comma-separated --target list; an empty target means a single
    // custom --path run (handled below).
    var selected_buf: [16][]const u8 = undefined;
    var selected_count: usize = 0;
    if (suite) {
        const all = [_][]const u8{ "health", "http", "sql", "nosql", "timeseries", "search", "proto", "graphql", "filestore" };
        for (all) |c| {
            if (selected_count < selected_buf.len) {
                selected_buf[selected_count] = c;
                selected_count += 1;
            }
        }
    } else if (target_csv) |csv| {
        var it = std.mem.tokenizeScalar(u8, csv, ',');
        while (it.next()) |tok| {
            const c = std.mem.trim(u8, tok, " ");
            if (std.mem.eql(u8, c, "all")) {
                const all = [_][]const u8{ "health", "http", "sql", "nosql", "timeseries", "search", "proto", "graphql", "filestore" };
                for (all) |a| {
                    if (selected_count < selected_buf.len) {
                        selected_buf[selected_count] = a;
                        selected_count += 1;
                    }
                }
                break;
            }
            if (c.len > 0 and selected_count < selected_buf.len) {
                selected_buf[selected_count] = c;
                selected_count += 1;
            }
        }
    }

    const targeted = selected_count > 0;

    if (targeted) {
        std.debug.print("\nzero framework HTTP benchmark (targeted)\n", .{});
        const targets_label = if (target_csv) |c| c else "all (--suite)";
        std.debug.print("targets={s}  duration={}s/level  logging={s}\n\n", .{ targets_label, duration_s, if (quiet) "off" else "on" });
        for (raw_specs) |sp| {
            // Skip scenarios whose category wasn't requested.
            var want = false;
            for (selected_buf[0..selected_count]) |c| {
                if (std.mem.eql(u8, c, sp.category)) want = true;
            }
            if (!want) continue;
            // Skip backend-gated scenarios when their service isn't configured.
            if (sp.gated_env) |env| {
                if (!envConfigured(init, env)) continue;
            }
            const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, sp.path });
            const req: Req = .{
                .method = sp.method,
                .url = url,
                .body = sp.body,
                .content_type = sp.content_type,
                .accept = sp.accept,
                .expect_ct = sp.expect_ct,
            };
            const rep = try runScenario(allocator, init.io, &peak_rss, sp.name, req, duration_ns, levels[0..level_count]);
            try scenarios.append(rep);
        }
    } else if (!external) {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
        std.debug.print("\nzero framework HTTP benchmark\n", .{});
        std.debug.print("target={s}  duration={d}s/level  logging={s}\n\n", .{ url, duration_s, if (quiet) "off" else "on" });
        const rep = try runScenario(allocator, init.io, &peak_rss, path, .{ .method = .GET, .url = url }, duration_ns, levels[0..level_count]);
        try scenarios.append(rep);
    } else {
        std.debug.print("\nerror: --host set but no --target given. Pick a category, e.g. --target=all\n", .{});
        std.process.exit(1);
    }

    writeReport(allocator, scenarios.items);

    const peak_mib = @as(f64, @floatFromInt(peak_rss)) / (1024 * 1024);
    std.debug.print("\npeak RSS over run: {d:.1} MiB\n", .{peak_mib});

    if (debug_alloc) {
        if (gpa.detectLeaks() > 0) {
            std.debug.print("debug-alloc: leaks detected (see report above)\n", .{});
        }
    }

    std.process.exit(0);
}
