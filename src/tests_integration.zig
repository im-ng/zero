const std = @import("std");

// Root module for integration tests that require a real database driver. These
// are intentionally excluded from the kcov coverage step (the native driver
// aborts under ptrace) and run via `zig build test-integration`.
pub const integration = @import("datasource/integration_test.zig");

comptime {
    _ = integration;
}
