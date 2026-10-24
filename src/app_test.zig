const std = @import("std");
const root = @import("zero.zig");
const httpz = root.httpz;
const app = @import("app.zig");

const Context = root.Context;
const health = app.health;
const startup = app.startup;

// Tests for app.zig (1533 lines) split out so the source file stays free of
// test code. Only tests reachable through `pub` symbols live here: the
// `safeStaticPath` test stays in app.zig because the helper is file-private.

test "parseLogLevel / logLevelName round-trip" {
    try std.testing.expectEqual(@as(?u8, 0), app.parseLogLevel("debug"));
    try std.testing.expectEqual(@as(?u8, 1), app.parseLogLevel("info"));
    try std.testing.expectEqual(@as(?u8, 2), app.parseLogLevel("warn"));
    try std.testing.expectEqual(@as(?u8, 3), app.parseLogLevel("error"));
    try std.testing.expectEqual(@as(?u8, 4), app.parseLogLevel("fatal"));
    try std.testing.expectEqual(@as(?u8, 99), app.parseLogLevel("none"));
    try std.testing.expectEqual(@as(?u8, null), app.parseLogLevel("verbose"));
    try std.testing.expectEqual(@as(?u8, null), app.parseLogLevel(""));

    try std.testing.expectEqualStrings("debug", app.logLevelName(0));
    try std.testing.expectEqualStrings("info", app.logLevelName(1));
    try std.testing.expectEqualStrings("warn", app.logLevelName(2));
    try std.testing.expectEqualStrings("error", app.logLevelName(3));
    try std.testing.expectEqualStrings("fatal", app.logLevelName(4));
    try std.testing.expectEqualStrings("none", app.logLevelName(99));
    try std.testing.expectEqualStrings("none", app.logLevelName(7));
}

test "app: health aggregates custom checks and reports 503 on failure" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var c: root.container = .{ .allocator = testing.arena };
    c.appName = "demo";
    c.appVersion = "9.9";
    c.healthChecks = std.array_list.Managed(root.container.HealthCheck).init(testing.arena);

    const ok: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {}
    }.f;
    const bad: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {
            return error.Sick;
        }
    }.f;

    try c.healthChecks.append(.{ .name = "cache", .check = ok });
    try c.healthChecks.append(.{ .name = "billing", .check = bad });

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.container = &c;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try health(&ctx);
    const pr = try testing.parseResponse();
    try std.testing.expectEqual(@as(u16, 503), pr.status);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "DOWN") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "billing") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "cache") != null);
}

test "app: health reports 200 UP when all custom checks pass" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var c: root.container = .{ .allocator = testing.arena };
    c.appName = "demo";
    c.appVersion = "9.9";
    c.healthChecks = std.array_list.Managed(root.container.HealthCheck).init(testing.arena);

    const ok: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {}
    }.f;
    try c.healthChecks.append(.{ .name = "cache", .check = ok });

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.container = &c;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try health(&ctx);
    const pr = try testing.parseResponse();
    try std.testing.expectEqual(@as(u16, 200), pr.status);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "UP") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "cache") != null);
}

test "app: startup probe reports 503 before ready and 200 after" {
    const t = httpz.testing;

    var c: root.container = .{ .allocator = std.testing.allocator };
    c.appName = "demo";
    c.appVersion = "9.9";
    // `started` defaults to false; the container above did not call App.run().
    try std.testing.expectEqual(false, c.started.load(.monotonic));

    // Before ready: fresh testing context so the response buffer is clean.
    {
        var testing = t.init(.{});
        defer testing.deinit();
        var ctx: Context = undefined;
        ctx.allocator = testing.arena;
        ctx.container = &c;
        ctx.request = testing.req;
        ctx.response = testing.res;

        try startup(&ctx);
        const pr = try testing.parseResponse();
        try std.testing.expectEqual(@as(u16, 503), pr.status);
        try std.testing.expect(std.mem.indexOf(u8, pr.body, "DOWN") != null);
    }

    // Simulate App.run() having finished wiring and the server listening.
    c.started.store(true, .monotonic);
    {
        var testing = t.init(.{});
        defer testing.deinit();
        var ctx: Context = undefined;
        ctx.allocator = testing.arena;
        ctx.container = &c;
        ctx.request = testing.req;
        ctx.response = testing.res;

        try startup(&ctx);
        const pr = try testing.parseResponse();
        try std.testing.expectEqual(@as(u16, 200), pr.status);
        try std.testing.expect(std.mem.indexOf(u8, pr.body, "UP") != null);
    }
}
