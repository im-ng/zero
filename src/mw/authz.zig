const std = @import("std");
const root = @import("../zero.zig");

const authz = @This();
const httpz = root.httpz;
const HandlerError = root.httpz.HandlerError;
const zul = root.zul;
const constants = root.constants;
const utils = root.utils;

const AuthError = root.AuthProvider.AuthError;
const AuthMode = root.AuthProvider.AuthMode;

allocator: std.mem.Allocator,
container: ?*root.container = undefined,
provider: ?*root.AuthProvider = undefined,

pub const Config = struct {
    allocator: std.mem.Allocator,
    container: *root.container,
    provider: ?*root.AuthProvider,
};

pub fn init(c: Config) !authz {
    return .{
        .allocator = c.allocator,
        .container = c.container,
        .provider = c.provider,
    };
}

pub fn execute(self: *const authz, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (self.provider == null) {
        return executor.next();
    }

    if (self.isWellKnownPath(req)) {
        return executor.next();
    }

    if (self.provider) |provider| {
        switch (provider.mode) {
            .Basic => {
                const buffer = try utils.combine(req.arena, "auth basic provider called", .{});
                self.container.?.log.Info(req.arena, buffer);

                const header = req.header(constants.AUTH_HEADER);
                if (header == null) {
                    self.deny(res, req.arena, "authorization header is not found.");
                    return;
                }

                provider.validateBasicAuth(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthKeyHeader => {
                        self.deny(res, req.arena, "invalid authorization header found");
                        return;
                    },
                    else => {},
                };
            },
            .APIKey => {
                const buffer = try utils.combine(req.arena, "auth api key called", .{});
                self.container.?.log.info(buffer);

                const header = req.header(constants.APIKEY_HEADER);
                if (header == null) {
                    self.deny(res, req.arena, "api key header is not found.");
                    return;
                }

                provider.validateAPIKeyAuth(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthAPIHeader => {
                        self.deny(res, req.arena, "invalid jwt header found");
                        return;
                    },
                    else => {},
                };
            },
            .OAuth => {
                const buffer = try utils.combine(req.arena, "auth oauth called", .{});
                self.container.?.log.Info(req.arena, buffer);

                const header = req.header(constants.AUTH_HEADER);
                if (header == null) {
                    self.deny(res, req.arena, "authorization header is not found.");
                    return;
                }

                provider.validateOAuthToken(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthToken => {
                        self.deny(res, req.arena, "invalid auth token found");
                        return;
                    },
                    AuthError.TokenInvalidClaims => {
                        self.deny(res, req.arena, "invalid token claims found");
                        return;
                    },
                    else => {},
                };
            },
            else => {
                const buffer = try utils.combine(req.arena, "unknown auth provider called", .{});
                self.container.?.log.Info(req.arena, buffer);
            },
        }
    }

    return executor.next();
}

/// Log a denial and set 401. Centralizes the repeated "header/claims invalid"
/// branches so each auth mode stays a thin switch arm.
fn deny(self: *const authz, res: *httpz.Response, arena: std.mem.Allocator, comptime msg: []const u8) void {
    const buffer = utils.combine(arena, msg, .{}) catch "auth denied";
    self.container.?.log.Info(arena, buffer);
    res.setStatus(.unauthorized);
}

fn isWellKnownPath(_: *const authz, req: *httpz.Request) bool {
    if (std.mem.eql(u8, req.url.path, constants.HEALTH_PATH)) {
        return true;
    }

    if (std.mem.eql(u8, req.url.path, constants.LIVE_PATH)) {
        return true;
    }

    if (std.mem.startsWith(u8, req.url.path, constants.WELL_KNOWN)) {
        return true;
    }

    if (std.mem.eql(u8, req.url.path, constants.METRICS_PATH)) {
        return true;
    }

    return false;
}

/// Minimal container with a real logger so the authz middleware's logging
/// paths (which dereference `self.container.?.log`) work in isolation.
fn testContainer(allocator: std.mem.Allocator) !root.container {
    const log = try root.logger.create(allocator);
    return root.container{
        .allocator = allocator,
        .log = log,
    };
}

/// Records whether the next middleware in the chain was invoked.
const MockExecutor = struct {
    next_called: *bool,
    pub fn next(self: MockExecutor) !void {
        self.next_called.* = true;
    }
};

// ===================== Tests =====================

test "well-known path constants are correct" {
    try std.testing.expectEqualStrings("/.well-known/health", constants.HEALTH_PATH);
    try std.testing.expectEqualStrings("/.well-known/live", constants.LIVE_PATH);
    try std.testing.expectEqualStrings("/metrics", constants.METRICS_PATH);
    try std.testing.expectEqualStrings("./well-known/", constants.WELL_KNOWN);
}

test "authz Config struct can be initialized" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .allocator = allocator,
        .container = undefined,
        .provider = null,
    };
    try std.testing.expect(cfg.provider == null);
}

test "authz blocks request when api key header is missing" {
    const alloc = std.testing.allocator;
    var c = try testContainer(alloc);
    defer c.log.deinit();

    var provider_keys = std.StringHashMap([]const u8).init(alloc);
    defer provider_keys.deinit();
    var provider = root.AuthProvider{ .mode = .APIKey, .container = &c, .keys = provider_keys };

    var az = try authz.init(.{ .allocator = alloc, .container = &c, .provider = &provider });

    var ht = root.httpz.testing.init(root.httpz.Config{});
    defer ht.deinit();
    ht.url("/api/secret");

    var next_called = false;
    try az.execute(ht.req, ht.res, MockExecutor{ .next_called = &next_called });

    try std.testing.expect(next_called == false);
    try std.testing.expect(ht.res.status == @intFromEnum(std.http.Status.unauthorized));
}

test "authz blocks request when api key is invalid" {
    const alloc = std.testing.allocator;
    var c = try testContainer(alloc);
    defer c.log.deinit();

    var keys = std.StringHashMap([]const u8).init(alloc);
    defer keys.deinit();
    try keys.put("known-key", "valid");

    var provider = root.AuthProvider{ .mode = .APIKey, .container = &c, .keys = keys };
    var az = try authz.init(.{ .allocator = alloc, .container = &c, .provider = &provider });

    var ht = root.httpz.testing.init(root.httpz.Config{});
    defer ht.deinit();
    ht.url("/api/secret");
    ht.header(constants.APIKEY_HEADER, "ApiKey wrong-key");

    var next_called = false;
    try az.execute(ht.req, ht.res, MockExecutor{ .next_called = &next_called });

    try std.testing.expect(next_called == false);
    try std.testing.expect(ht.res.status == @intFromEnum(std.http.Status.unauthorized));
}

test "authz proceeds to next when api key is valid" {
    const alloc = std.testing.allocator;
    var c = try testContainer(alloc);
    defer c.log.deinit();

    var keys = std.StringHashMap([]const u8).init(alloc);
    defer keys.deinit();
    try keys.put("known-key", "valid");

    var provider = root.AuthProvider{ .mode = .APIKey, .container = &c, .keys = keys };
    var az = try authz.init(.{ .allocator = alloc, .container = &c, .provider = &provider });

    var ht = root.httpz.testing.init(root.httpz.Config{});
    defer ht.deinit();
    ht.url("/api/secret");
    ht.header(constants.APIKEY_HEADER, "ApiKey known-key");

    var next_called = false;
    try az.execute(ht.req, ht.res, MockExecutor{ .next_called = &next_called });

    try std.testing.expect(next_called == true);
    try std.testing.expect(ht.res.status == @intFromEnum(std.http.Status.ok));
}

test "authz bypasses well-known paths without auth" {
    const alloc = std.testing.allocator;
    var c = try testContainer(alloc);
    defer c.log.deinit();

    var provider_keys = std.StringHashMap([]const u8).init(alloc);
    defer provider_keys.deinit();
    var provider = root.AuthProvider{ .mode = .APIKey, .container = &c, .keys = provider_keys };
    var az = try authz.init(.{ .allocator = alloc, .container = &c, .provider = &provider });

    var ht = root.httpz.testing.init(root.httpz.Config{});
    defer ht.deinit();
    ht.url(constants.HEALTH_PATH);

    var next_called = false;
    try az.execute(ht.req, ht.res, MockExecutor{ .next_called = &next_called });

    try std.testing.expect(next_called == true);
}

test "authz proceeds when no provider is configured" {
    const alloc = std.testing.allocator;
    var c = try testContainer(alloc);
    defer c.log.deinit();

    var az = try authz.init(.{ .allocator = alloc, .container = &c, .provider = null });

    var ht = root.httpz.testing.init(root.httpz.Config{});
    defer ht.deinit();
    ht.url("/api/secret");

    var next_called = false;
    try az.execute(ht.req, ht.res, MockExecutor{ .next_called = &next_called });

    try std.testing.expect(next_called == true);
}
