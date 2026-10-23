const std = @import("std");
const root = @import("../zero.zig");
const Client = @import("client.zig");

// Tests for service/client.zig (981 lines) split out so the source file stays
// free of test code. Only tests reachable through `pub` symbols live here:
// the `isConnectionError` test stays in client.zig because that helper is
// file-private.

test "client: downstream rate limiter is created from options and trips" {
    // Allocate everything in an arena and free the arena afterwards: a full
    // zul.Client.deinit() needs a live Io loop that unit tests don't provide,
    // so we avoid it and just release the arena (no leak, no crash).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c: root.container = .{ .allocator = alloc };
    const cli = try Client.createWithConfig(
        &c,
        "svc",
        "http://localhost",
        .{ .rateLimiter = .{ .allocator = alloc, .enabled = true, .limit = 1, .window_ms = 60_000 } },
    );

    // Limiter instance is wired from ServiceOptions.
    try std.testing.expect(cli.limiter != null);

    // First call allowed, second exceeds the per-service window. Exercises the
    // same gate used by createAndSendRequest (no network involved here).
    try cli.limiter.?.before();
    try std.testing.expectError(error.RateLimited, cli.limiter.?.before());
}
