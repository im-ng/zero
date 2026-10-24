const std = @import("std");
const container = @import("container.zig");

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
