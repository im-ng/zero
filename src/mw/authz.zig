const std = @import("std");
const root = @import("../zero.zig");

const authz = @This();
const httpz = root.httpz;
const HandlerError = root.httpz.HandlerError;
const zul = root.zul;
const constants = root.constants;
const utils = root.utils;

const AuthError = root.AuthProvder.AuthError;
const AuthMode = root.AuthProvder.AuthMode;

allocator: std.mem.Allocator,
container: ?*root.container = undefined,
provider: ?*root.AuthProvder = undefined,

pub const Config = struct {
    allocator: std.mem.Allocator,
    container: *root.container,
    provider: ?*root.AuthProvder,
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
                var buffer = try utils.combine(req.arena, "auth basic provider called", .{});
                self.container.?.log.Info(req.arena, buffer);

                const header = req.header(constants.AUTH_HEADER);
                if (header == null) {
                    buffer = try utils.combine(req.arena, "authorization header is not found.", .{});
                    self.container.?.log.Info(req.arena, buffer);

                    res.setStatus(.unauthorized);
                    return executor.next();
                }

                provider.validateBasicAuth(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthKeyHeader => {
                        buffer = try utils.combine(req.arena, "invalid authorization header found", .{});
                        self.container.?.log.Info(req.arena, buffer);

                        res.setStatus(.unauthorized);
                        return executor.next();
                    },
                    else => {
                        //do nothing
                    },
                };
            },
            .APIKey => {
                var buffer = try utils.combine(req.arena, "auth api key called", .{});
                self.container.?.log.info(buffer);

                const header = req.header(constants.APIKEY_HEADER);
                if (header == null) {
                    buffer = try utils.combine(req.arena, "api key header is not found.", .{});
                    self.container.?.log.Info(req.arena, buffer);

                    res.setStatus(.unauthorized);
                    return executor.next();
                }

                provider.validateAPIKeyAuth(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthAPIHeader => {
                        buffer = try utils.combine(req.arena, "invalid jwt header found", .{});
                        self.container.?.log.Info(req.arena, buffer);

                        res.setStatus(.unauthorized);
                        return executor.next();
                    },
                    else => {
                        //do nothing
                    },
                };
            },
            .OAuth => {
                var buffer = try utils.combine(req.arena, "auth oauth called", .{});
                self.container.?.log.Info(req.arena, buffer);

                const header = req.header(constants.AUTH_HEADER);
                if (header == null) {
                    buffer = try utils.combine(req.arena, "authorization header is not found.", .{});
                    self.container.?.log.Info(req.arena, buffer);

                    res.setStatus(.unauthorized);
                    return executor.next();
                }

                provider.validateOAuthToken(req.arena, header.?) catch |err| switch (err) {
                    AuthError.InvalidAuthToken => {
                        buffer = try utils.combine(req.arena, "invalid auth token found", .{});
                        self.container.?.log.Info(req.arena, buffer);

                        res.setStatus(.unauthorized);
                        return executor.next();
                    },
                    AuthError.TokenInvalidClaims => {
                        buffer = try utils.combine(req.arena, "invalid token claims found", .{});
                        self.container.?.log.Info(req.arena, buffer);

                        res.setStatus(.unauthorized);
                        return executor.next();
                    },
                    else => {
                        //do nothing
                    },
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
