const std = @import("std");
const container = @import("container.zig");
const utils = @import("utils.zig");

const StaticMount = container.StaticMount;
const staticResolve = container.staticResolve;

// Tests for the container/StaticMount helpers split out of container.zig
// (1802 lines) so the source file stays free of test code.

test "staticResolve matches mount with path boundary" {
    const mounts = [_]StaticMount{
        .{ .prefix = "/assets", .dir = "/var/www" },
        .{ .prefix = "/public", .dir = "/srv" },
    };
    const hit = staticResolve(&mounts, "/assets/logo.png").?;
    try std.testing.expectEqualStrings("/var/www", hit.mount.dir);
    try std.testing.expectEqualStrings("/logo.png", hit.rel);

    // mount root resolves with empty rel
    const rmt = staticResolve(&mounts, "/public").?;
    try std.testing.expectEqualStrings("/srv", rmt.mount.dir);
    try std.testing.expectEqualStrings("", rmt.rel);

    // prefix must be a path boundary, not a substring
    try std.testing.expect(staticResolve(&mounts, "/assets2/x") == null);
    try std.testing.expect(staticResolve(&mounts, "/nope/x") == null);
}

test "runHealthCheckBounded reports the real check result (argon T17)" {
    // T17: a health check must report its real outcome, never a stale success and
    // never crash on a failing check. Run as the synchronous probe (the bounded
    // pre-emptive timeout is deferred to a cancelable std.Io task; the harness
    // listener can't exercise a non-blocking thread wait), so a healthy check is
    // UP and a throwing check is DOWN.
    var c: container = .{ .allocator = std.testing.allocator };

    var healthy: container.HealthCheck = .{
        .name = "cache",
        .check = struct {
            fn check(_: *container) anyerror!void {}
        }.check,
    };
    try std.testing.expect(c.runHealthCheckBounded(&healthy, 20));

    var failing: container.HealthCheck = .{
        .name = "billing",
        .check = struct {
            fn check(_: *container) anyerror!void {
                return error.DependencyDown;
            }
        }.check,
    };
    try std.testing.expect(!c.runHealthCheckBounded(&failing, 20));
}
