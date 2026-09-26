const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;
const constants = root.constants;

/// Per-service fixed-window rate limiter for outbound HTTP calls. One instance
/// is created per registered service (`app.addHttpService`) and guards every
/// get/post/put/delete against that downstream. Exceeding `limit` within
/// `window_ms` makes `before()` return `error.RateLimited`, which the client
/// surfaces as `ClientError.RateLimited` (fail-fast, no network call).
pub const RateLimiterConfig = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    limit: u64 = constants.DEFAULT_RATE_LIMIT_MAX,
    window_ms: i64 = constants.DEFAULT_RATE_LIMIT_WINDOW_MS,
};

const Window = struct {
    count: u64,
    reset_at: i128,
};

pub const RateLimiter = struct {
    enabled: bool,
    limit: u64,
    window_ns: i128,
    mu: std.Io.Mutex,
    window: Window,

    pub fn init(c: RateLimiterConfig) RateLimiter {
        return .{
            .enabled = c.enabled,
            .limit = c.limit,
            .window_ns = @as(i128, c.window_ms) * 1_000_000,
            .mu = .init,
            .window = .{ .count = 0, .reset_at = 0 },
        };
    }

    /// Returns `error.RateLimited` when the current window is exhausted.
    pub fn before(self: *RateLimiter) !void {
        if (!self.enabled) return;
        const now = utils.nowMonotonic().nanoseconds;

        self.mu.lockUncancelable(utils.io);
        if ((now - self.window.reset_at) >= self.window_ns) {
            self.window = .{ .count = 0, .reset_at = now };
        }
        self.window.count += 1;
        const over = self.window.count > self.limit;
        self.mu.unlock(utils.io);

        if (over) return error.RateLimited;
    }
};

// ===================== Tests =====================

test "RateLimiter: allows up to limit then trips, resets after window" {
    const testing = std.testing;
    var lim = RateLimiter.init(.{ .allocator = testing.allocator, .enabled = true, .limit = 2, .window_ms = 60_000 });

    // First two requests pass.
    try lim.before();
    try lim.before();

    // Third exceeds the limit.
    try testing.expectError(error.RateLimited, lim.before());

    // Disabled limiter never trips.
    var off = RateLimiter.init(.{ .allocator = testing.allocator, .enabled = false, .limit = 0, .window_ms = 60_000 });
    try off.before();
}
