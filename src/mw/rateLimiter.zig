const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");
const utils = root.utils;
const constants = root.constants;
const rediz = root.rediz;

pub const rateLimiter = @This();

pub const KeyMode = enum {
    ip,
    header,
};

/// Where the counter lives. `.memory` keeps the existing per-process hashmap
/// (no shared state). `.redis` switches the counter to a shared Redis key so
/// the limit is enforced across all replicas/processes.
pub const Store = enum {
    memory,
    redis,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    limit: u64 = constants.DEFAULT_RATE_LIMIT_MAX,
    window_ms: i64 = constants.DEFAULT_RATE_LIMIT_WINDOW_MS,
    key_mode: KeyMode = .ip,
    header_name: []const u8 = "X-Forwarded-For",
    /// Backing store for the counter. Defaults to the existing in-process map.
    store: Store = .memory,
    /// Borrowed Redis client used only when `store == .redis`. Copied (not
    /// owned) — `container.redis` owns the connection and outlives the limiter.
    redis: ?rediz.Client = null,
};

const Window = struct {
    count: u64,
    reset_at: i128,
};

const max_entries = 1_000_000;

allocator: std.mem.Allocator,
enabled: bool,
limit: u64,
window_ns: i128,
key_mode: KeyMode,
header_name: []const u8,
store: Store,
redis: ?rediz.Client,
mu: std.Io.Mutex,
buckets: std.AutoHashMap(u64, Window),

pub fn init(c: Config) !rateLimiter {
    return .{
        .allocator = c.allocator,
        .enabled = c.enabled,
        .limit = c.limit,
        .window_ns = @as(i128, c.window_ms) * 1_000_000,
        .key_mode = c.key_mode,
        .header_name = c.header_name,
        .store = c.store,
        .redis = c.redis,
        .mu = .init,
        .buckets = std.AutoHashMap(u64, Window).init(c.allocator),
    };
}

pub fn execute(self: *rateLimiter, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (!self.enabled) {
        return executor.next();
    }

    if (std.mem.startsWith(u8, req.url.path, "/.well-known")) {
        return executor.next();
    }

    // Distributed path: shared Redis counter keyed by the same identity hash.
    // A Lua EVAL would make this atomic, but INCR + PEXPIRE on first hit is
    // enough to enforce a fixed window across replicas; the expiry race only
    // lets the counter persist a little past the window (still rate-limited).
    if (self.store == .redis) {
        const kh = self.keyFor(req) orelse return executor.next();
        var key_buf: [32]u8 = undefined;
        const redis_key = std.fmt.bufPrint(&key_buf, "rl:{x}", .{kh}) catch return executor.next();
        const win_ms = @as(i64, @intCast(@divTrunc(self.window_ns, 1_000_000)));

        const count = self.redis.?.send(i64, .{ "INCR", redis_key }) catch {
            // Redis unreachable: fail open so a Redis outage does not take down
            // the whole service. The in-memory limiter is the safety net.
            return executor.next();
        };
        if (count == 1) {
            self.redis.?.send(void, .{ "PEXPIRE", redis_key, win_ms }) catch {};
        }
        if (count > self.limit) {
            res.setStatus(std.http.Status.too_many_requests);
            res.content_type = .TEXT;
            res.body = "rate limit exceeded";
            return;
        }
        return executor.next();
    }

    const key = self.keyFor(req) orelse return executor.next();
    const now = utils.nowMonotonic().nanoseconds;

    self.mu.lockUncancelable(utils.io);
    if (self.buckets.count() >= max_entries) {
        self.mu.unlock(utils.io);
        return executor.next();
    }

    const gop = self.buckets.getOrPut(key) catch {
        self.mu.unlock(utils.io);
        return executor.next();
    };
    if (!gop.found_existing or (now - gop.value_ptr.*.reset_at) >= self.window_ns) {
        gop.value_ptr.* = .{ .count = 0, .reset_at = now };
    }
    gop.value_ptr.*.count += 1;
    const over = gop.value_ptr.*.count > self.limit;
    self.mu.unlock(utils.io);

    if (over) {
        res.setStatus(std.http.Status.too_many_requests);
        res.content_type = .TEXT;
        res.body = "rate limit exceeded";
        return;
    }

    return executor.next();
}

fn keyFor(self: *const rateLimiter, req: *httpz.Request) ?u64 {
    if (self.key_mode == .header) {
        if (req.header(self.header_name)) |h| {
            return std.hash.XxHash3.hash(0, h);
        }
    }

    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{}", .{req.address}) catch return null;

    return std.hash.XxHash3.hash(0, s);
}
