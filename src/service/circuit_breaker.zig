const std = @import("std");
const utils = @import("../utils.zig");

pub const CircuitBreakerConfig = struct {
    failure_threshold: u32 = 5,
    cooldown_ms: u64 = 30_000,
    half_open_trials: u32 = 1,
};

pub const CircuitState = enum {
    closed,
    open,
    half_open,
};

pub const CircuitBreaker = struct {
    const Self = @This();

    cfg: CircuitBreakerConfig,
    state: CircuitState = .closed,
    failures: u32 = 0,
    trials_in_flight: u32 = 0,
    opened_at: i128 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(cfg: CircuitBreakerConfig) CircuitBreaker {
        return .{ .cfg = cfg };
    }

    fn nowNs() i128 {
        return utils.nowMonotonic().nanoseconds;
    }

    /// Call before issuing a request. Returns `error.CircuitOpen` when the
    /// breaker is open (and not within the half-open trial window).
    pub fn before(self: *Self) !void {
        self.mutex.lock(utils.io) catch {};
        defer self.mutex.unlock(utils.io);

        switch (self.state) {
            .closed => return,
            .open => {
                const elapsed = nowNs() - self.opened_at;
                if (elapsed < self.cfg.cooldown_ms * 1_000_000) {
                    return error.CircuitOpen;
                }
                // cooldown elapsed: allow a half-open trial
                self.state = .half_open;
                self.trials_in_flight = 0;
                if (self.trials_in_flight < self.cfg.half_open_trials) {
                    self.trials_in_flight += 1;
                    return;
                }
                return error.CircuitOpen;
            },
            .half_open => {
                if (self.trials_in_flight < self.cfg.half_open_trials) {
                    self.trials_in_flight += 1;
                    return;
                }
                return error.CircuitOpen;
            },
        }
    }

    pub fn recordSuccess(self: *Self) void {
        self.mutex.lock(utils.io) catch {};
        defer self.mutex.unlock(utils.io);

        switch (self.state) {
            .half_open => {
                self.state = .closed;
                self.failures = 0;
                self.trials_in_flight = 0;
            },
            .closed => {
                self.failures = 0;
            },
            .open => {},
        }
    }

    pub fn recordFailure(self: *Self) void {
        self.mutex.lock(utils.io) catch {};
        defer self.mutex.unlock(utils.io);

        switch (self.state) {
            .half_open => {
                self.state = .open;
                self.opened_at = nowNs();
                self.trials_in_flight = 0;
            },
            .closed => {
                self.failures += 1;
                if (self.failures >= self.cfg.failure_threshold) {
                    self.state = .open;
                    self.opened_at = nowNs();
                }
            },
            .open => {},
        }
    }

    pub fn snapshot(self: *Self) CircuitState {
        return self.state;
    }
};

test "circuit breaker stays closed then opens after threshold" {
    var cb = CircuitBreaker.init(.{});
    try cb.before();
    for (0..5) |_| {
        cb.recordFailure();
    }

    try std.testing.expectEqual(CircuitState.open, cb.snapshot());
    try std.testing.expectError(error.CircuitOpen, cb.before());
}

test "circuit breaker half-open recovers on success" {
    var cb = CircuitBreaker.init(.{ .cooldown_ms = 1 });
    for (0..5) |_| {
        cb.recordFailure();
    }

    try std.testing.expectEqual(CircuitState.open, cb.snapshot());
    cb.opened_at = 0;
    try cb.before(); // half-open trial allowed

    try std.testing.expectEqual(CircuitState.half_open, cb.snapshot());
    cb.recordSuccess();

    try std.testing.expectEqual(CircuitState.closed, cb.snapshot());
    try cb.before();
}

test "circuit breaker half-open reopens on failure" {
    var cb = CircuitBreaker.init(.{ .cooldown_ms = 1 });
    for (0..5) |_| {
        cb.recordFailure();
    }
    cb.opened_at = 0;

    try cb.before();
    cb.recordFailure();

    try std.testing.expectEqual(CircuitState.open, cb.snapshot());
    try std.testing.expectError(error.CircuitOpen, cb.before());
}

test "circuit breaker allows up to half_open_trials concurrent" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .cooldown_ms = 1, .half_open_trials = 2 });
    cb.recordFailure();

    cb.opened_at = 0;
    try cb.before();
    try cb.before();

    try std.testing.expectError(error.CircuitOpen, cb.before());
}
