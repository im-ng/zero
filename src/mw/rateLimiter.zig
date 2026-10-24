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
    /// When `key_mode == .header`, the `X-Forwarded-For` header is only trusted
    /// if the immediate peer is one of these proxy IPs. Otherwise a client could
    /// spoof the header and dodge the limit (audit #25). Empty = never trust the
    /// header; fall back to the peer address.
    trusted_proxies: []const []const u8 = &[0][]const u8{},
    /// When true, Redis errors / map-capacity exhaustion reject the request
    /// instead of failing open. Default false: a limiter/store outage must not
    /// take down the service (fail-open is the availability-safe default).
    fail_closed: bool = false,
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
trusted_proxies: []const []const u8,
fail_closed: bool,
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
        .trusted_proxies = c.trusted_proxies,
        .fail_closed = c.fail_closed,
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
            // Redis unreachable: by default fail open so a Redis outage does not
            // take down the whole service. `fail_closed` reverses this.
            if (self.fail_closed) {
                reject(res);
                return;
            }
            return executor.next();
        };
        if (count == 1) {
            self.redis.?.send(void, .{ "PEXPIRE", redis_key, win_ms }) catch {};
        }
        if (count > self.limit) {
            reject(res);
            return;
        }
        return executor.next();
    }

    const key = self.keyFor(req) orelse return executor.next();
    const now = utils.nowMonotonic().nanoseconds;

    self.mu.lockUncancelable(utils.io);
    if (self.buckets.count() >= max_entries) {
        self.mu.unlock(utils.io);
        // Map at capacity: fail open by default (availability); fail_closed
        // rejects so a poisoned/overflowing map can't be bypassed.
        if (self.fail_closed) {
            reject(res);
            return;
        }
        return executor.next();
    }

    const gop = self.buckets.getOrPut(key) catch {
        self.mu.unlock(utils.io);
        if (self.fail_closed) {
            reject(res);
            return;
        }
        return executor.next();
    };
    if (!gop.found_existing or (now - gop.value_ptr.*.reset_at) >= self.window_ns) {
        gop.value_ptr.* = .{ .count = 0, .reset_at = now };
    }
    gop.value_ptr.*.count += 1;
    const over = gop.value_ptr.*.count > self.limit;
    // Seconds remaining in the window, for the Retry-After header.
    const retry_after: i64 = @intCast(@max(1, @divTrunc(gop.value_ptr.*.reset_at - now + 999_999_999, 1_000_000_000)));
    self.mu.unlock(utils.io);

    if (over) {
        reject(res);
        setRetryAfter(res, retry_after);
        return;
    }

    return executor.next();
}

/// Respond 429 with a plain body (the `Retry-After` header is added separately,
/// audit #25).
fn reject(res: *httpz.Response) void {
    res.setStatus(std.http.Status.too_many_requests);
    res.content_type = .TEXT;
    res.body = "rate limit exceeded";
}

fn setRetryAfter(res: *httpz.Response, seconds: i64) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{seconds}) catch "1";
    res.header("Retry-After", s);
}

fn keyFor(self: *const rateLimiter, req: *httpz.Request) ?u64 {
    if (self.key_mode == .header and self.isTrustedPeer(req)) {
        if (req.header(self.header_name)) |h| {
            // Use the original client IP: the left-most entry of the chain, not
            // the proxy that appended its own. Trim whitespace around commas.
            var it = std.mem.splitScalar(u8, h, ',');
            const first = it.first();
            const trimmed = std.mem.trim(u8, first, " ");
            if (trimmed.len > 0) {
                return std.hash.XxHash3.hash(0, trimmed);
            }
        }
    }

    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{}", .{req.address}) catch return null;

    return std.hash.XxHash3.hash(0, s);
}

/// True if the immediate peer is a configured trusted proxy, so its forwarded
/// headers may be believed (audit #25). Without this, `X-Forwarded-For` is
/// client-controlled and trivially spoofable.
fn isTrustedPeer(self: *const rateLimiter, req: *httpz.Request) bool {
    if (self.trusted_proxies.len == 0) return false;
    var buf: [64]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{}", .{req.address}) catch return false;
    // Strip the trailing ":port" (and any IPv6 brackets) to compare just the IP.
    const ip = if (std.mem.lastIndexOfScalar(u8, full, ':')) |i| full[0..i] else full;
    const bare = if (ip.len >= 2 and ip[0] == '[')
        ip[1..(if (ip[ip.len - 1] == ']') ip.len - 1 else ip.len)]
    else
        ip;
    for (self.trusted_proxies) |tp| {
        if (std.mem.eql(u8, bare, tp)) return true;
    }
    return false;
}
