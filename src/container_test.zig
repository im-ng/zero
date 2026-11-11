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

test "runHealthCheck reports the real check result" {
    // T17: a health check must report its real outcome, never a stale success and
    // never crash on a failing check. Synchronous semantics are preserved for the
    // disabled-snapshot mode; snapshot mode (`refreshHealthSnapshot`) layers
    // off-path probing on top.
    var c: container = .{ .allocator = std.testing.allocator };

    var healthy: container.HealthCheck = .{
        .name = "cache",
        .check = struct {
            fn check(_: *container) anyerror!void {}
        }.check,
    };
    try std.testing.expect(c.runHealthCheck(&healthy));

    var failing: container.HealthCheck = .{
        .name = "billing",
        .check = struct {
            fn check(_: *container) anyerror!void {
                return error.DependencyDown;
            }
        }.check,
    };
    try std.testing.expect(!c.runHealthCheck(&failing));
}

// health snapshot: publish/serve, refresh via watchdogs,
// and the freshness gate.

fn okCheck(_: *container) anyerror!void {}

fn failingCheck(_: *container) anyerror!void {
    return error.DependencyDown;
}

/// Frees the snapshot `runAndPublishHealthChecks`/`refreshHealthSnapshot` last
/// published so the testing allocator reports no leaks, and drops the check list.
fn snapshotTeardown(c: *container) void {
    if (c.health_snapshot) |s| {
        std.testing.allocator.free(s);
        c.health_snapshot = null;
    }
    c.healthChecks.deinit();
}

test "runAndPublishHealthChecks seeds a fresh snapshot" {
    var c: container = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    c.healthChecks = std.array_list.Managed(container.HealthCheck).init(std.testing.allocator);
    try c.addHealthCheckEntry("cache", okCheck);
    try c.addHealthCheckEntry("billing", failingCheck);

    c.runAndPublishHealthChecks();

    const snap = c.health_snapshot.?;
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("cache", snap[0].name);
    try std.testing.expect(snap[0].up);
    try std.testing.expectEqualStrings("billing", snap[1].name);
    try std.testing.expect(!snap[1].up);

    // Fresh right after publish; the gate is off entirely when refresh is 0.
    try std.testing.expect(c.healthSnapshotFresh(5_000));
    try std.testing.expect(!c.healthSnapshotFresh(0));

    snapshotTeardown(&c);
}

test "refreshHealthSnapshot publishes watchdog results and frees finished boxes" {
    var c: container = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    c.healthChecks = std.array_list.Managed(container.HealthCheck).init(std.testing.allocator);
    try c.addHealthCheckEntry("cache", okCheck);
    try c.addHealthCheckEntry("billing", failingCheck);

    // Short deadline: both watchdogs finish instantly, so the snapshot holds the
    // real outcomes and the slots can be reaped afterward (leak-proof check).
    c.refreshHealthSnapshot(500);
    defer snapshotTeardown(&c);

    const snap = c.health_snapshot.?;
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expect(snap[0].up);
    try std.testing.expect(!snap[1].up);

    c.reapDoneProbes();
    for (c.health_probe_slots) |slot| {
        try std.testing.expect(slot == null);
    }
}
