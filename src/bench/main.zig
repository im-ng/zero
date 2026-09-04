const std = @import("std");
const zero = @import("zero");
const zul = @import("zul");

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
    url: []const u8,
    duration_ns: u64,
    histo: *Histogram,
    errors: *std.atomic.Value(usize),
    io: Io,
};

fn appRun(app: *App) void {
    app.run() catch |e| {
        std.debug.print("server error: {any}\n", .{e});
    };
}

var first_err_printed = std.atomic.Value(bool).init(false);
var first_status_printed = std.atomic.Value(bool).init(false);

fn printFirstErr(e: anyerror) void {
    if (!first_err_printed.swap(true, .monotonic)) {
        std.debug.print("first error: {any}\n", .{e});
    }
}

fn fire(client: *zul.http.Client, url: []const u8) bool {
    const req = std.heap.page_allocator.create(zul.http.Request) catch return false;
    req.* = client.request(url) catch |e| {
        std.heap.page_allocator.destroy(req);
        printFirstErr(e);
        return false;
    };
    const res = std.heap.page_allocator.create(zul.http.Response) catch {
        req.deinit();
        std.heap.page_allocator.destroy(req);
        return false;
    };
    req.header("Connection", "close") catch {};
    res.* = req.getResponse(.{}) catch |e| {
        req.deinit();
        std.heap.page_allocator.destroy(req);
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
    req.deinit();
    std.heap.page_allocator.destroy(req);
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
        _ = fire(client, w.url);
    }

    const deadline = nowNs() + w.duration_ns;
    while (nowNs() < deadline) {
        const start = nowNs();
        if (fire(client, w.url)) {
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
        if (fire(client, url)) return;
        Io.sleep(io, .fromMilliseconds(50), .real) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var duration_s: f64 = 3;
    var quiet = true;
    var path: []const u8 = "/.well-known/health";
    var levels: [16]usize = .{ 1, 10, 50, 100, 200, 500, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var level_count: usize = 7;

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
        }
    }

    const allocator = std.heap.page_allocator;
    const app = try App.new(allocator, init.environ_map);
    if (quiet) app.log.logLevel = 99;
    const srv_thread = try std.Thread.spawn(.{}, appRun, .{app});
    _ = srv_thread;

    const port = app.httpServer.port;
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
    const health_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/.well-known/health", .{port});
    waitReady(init.io, health_url);

    const duration_ns = @as(u64, @intFromFloat(duration_s * 1_000_000_000.0));
    var errors = std.atomic.Value(usize).init(0);
    var peak_rss: u64 = 0;

    std.debug.print("\nzero framework HTTP benchmark\n", .{});
    std.debug.print("target={s}  duration={d}s/level  logging={s}\n\n", .{ url, duration_s, if (quiet) "off" else "on" });
    std.debug.print("concurrency   req/s        p50(us)   p95(us)   p99(us)   max(us)   errors   rss(MiB)   dRss(KiB)\n", .{});

    for (levels[0..level_count]) |c| {
        errors.store(0, .monotonic);
        const rss0 = readRss();
        const workers = try allocator.alloc(Worker, c);
        const threads = try allocator.alloc(std.Thread, c);
        const histos = try allocator.alloc(Histogram, c);
        for (histos) |*h| h.* = Histogram{};

        var i: usize = 0;
        while (i < c) : (i += 1) {
            workers[i] = .{
                .url = url,
                .duration_ns = duration_ns,
                .histo = &histos[i],
                .errors = &errors,
                .io = init.io,
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
        if (rss1 > peak_rss) peak_rss = rss1;
        const rss_mib = @as(f64, @floatFromInt(rss1)) / (1024 * 1024);
        const drss_kib = @as(f64, @floatFromInt(rss1 -% rss0)) / 1024;

        std.debug.print("{d:>9}   {d:>10.0}   {d:>9}   {d:>9}   {d:>9}   {d:>8}   {d:>6}   {d:>8.1}   {d:>9.1}\n", .{
            c, rps, p50, p95, p99, max_us, errors.load(.monotonic), rss_mib, drss_kib,
        });

        allocator.free(workers);
        allocator.free(threads);
        allocator.free(histos);
    }

    const peak_mib = @as(f64, @floatFromInt(peak_rss)) / (1024 * 1024);
    std.debug.print("\npeak RSS over run: {d:.1} MiB\n", .{peak_mib});

    std.process.exit(0);
}
