const std = @import("std");

// Root module for the memory-validation harness. These tests intentionally use
// a byte-counting allocator to prove whether memory allocated under a
// zero.Context is released after each HTTP request, cron tick, and pubsub
// message. They are excluded from the kcov coverage step (like the real-db
// integration tests) and run via `zig build test-validation`.
pub const validation = @import("validation/memory_test.zig");

comptime {
    _ = validation;
}
