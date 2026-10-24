const std = @import("std");
const utils = @import("../utils.zig");
const constants = @import("../constants.zig");

pub const CircuitBreakerConfig = struct {
    failure_threshold: u32 = constants.DEFAULT_CB_FAILURE_THRESHOLD,
    cooldown_ms: u64 = constants.DEFAULT_CB_COOLDOWN_MS,
    half_open_trials: u32 = constants.DEFAULT_CB_HALF_OPEN_TRIALS,
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
    /// When the breaker entered `half_open`. Used to self-heal: a half-open
    /// trial that never reports a result (e.g. the downstream returned a
    /// terminal 404 with no success/failure recorded) must not pin the breaker
    /// in `half_open` forever (audit #24: stuck half-open).
    half_open_at: i128 = 0,
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

        const now = nowNs();
        switch (self.state) {
            .closed => return,
            .open => {
                const elapsed = now - self.opened_at;
                if (elapsed < self.cfg.cooldown_ms * 1_000_000) {
                    return error.CircuitOpen;
                }
                // Cooldown elapsed: move to half-open and permit a single trial.
                // Record the entry time so a trial that never reports can revert.
                self.state = .half_open;
                self.trials_in_flight = 0;
                self.half_open_at = now;
                self.trials_in_flight += 1;
                return;
            },
            .half_open => {
                // Self-heal: if half-open has lingered past the cooldown window
                // without a recorded result, revert to open and re-attempt later
                // instead of rejecting every request forever.
                if (now - self.half_open_at >= self.cfg.cooldown_ms * 1_000_000) {
                    self.state = .open;
                    self.opened_at = now;
                    self.trials_in_flight = 0;
                    return error.CircuitOpen;
                }
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

// ===================== Tests =====================

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
