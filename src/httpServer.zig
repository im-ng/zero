const std = @import("std");
const root = @import("zero.zig");
const Thread = std.Thread;
const httpz = root.httpz;
const constants = root.constants;
const Context = root.Context;
const tracz_mw = root.tracz;
const cors_mw = root.httpz.middleware.Cors;
const auth_mw = root.authz;
const utils = root.utils;
const ws_mw = root.WSMiddleware;

const server = @This();
const Self = @This();

const decode = std.base64.Base64Decoder;

const authProvider = root.AuthProvder;
const AuthMode = authProvider.AuthMode;
const AuthError = authProvider.AuthError;
const PubKey = authProvider.publiKey;

const corsConfig = cors_mw.Config{
    .headers = "Authorization, Content-Type, x-requested-with, origin, true-client-ip, X-Correlation-ID",
    .methods = "GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS",
    .origin = "*",
    .max_age = "300",
};

port: u16 = 0,
container: *root.container = undefined,
http: httpz.Server(*root.handler.Handler) = undefined,
handler: root.handler.Handler = undefined,
router: *httpz.Router(*root.handler.Handler, *const fn (*root.Context) anyerror!void) = undefined,
buffer: [1024]u8 = undefined,
provider: ?*root.AuthProvder = undefined,
refresherThread: ?std.Thread = undefined,

pub fn create(allocator: std.mem.Allocator, container: *root.container) !*server {
    const hzs = try allocator.create(server);
    errdefer allocator.destroy(hzs);

    hzs.* = .{
        .container = container,
    };

    hzs.port = try container.config.getAsInt("HTTP_PORT");
    if (hzs.port == 0) {
        hzs.port = constants.HTTP_PORT;
    }

    hzs.handler = root.handler.Handler{
        .container = hzs.container,
    };

    hzs.http = try httpz.Server(*root.handler.Handler).init(
        hzs.container.allocator,
        .{
            .port = hzs.port,
        },
        &hzs.handler,
    );

    const traczMW = try hzs.http.middleware(tracz_mw, .{
        .allocator = allocator,
    });

    const corsMW = try hzs.http.middleware(cors_mw, corsConfig);

    // initialize auth provider for the app
    hzs.provider = try hzs.loadAuthProviderConfig();

    // prepare auth middleware based on provider
    const authMW = try hzs.http.middleware(auth_mw, .{
        .allocator = allocator,
        .container = hzs.container,
        .provider = hzs.provider,
    });

    const mwWS = try hzs.http.middleware(ws_mw, .{
        .allocator = allocator,
        .container = container,
    });

    hzs.router = try hzs.http.router(.{
        .middlewares = &.{ traczMW, corsMW, authMW, mwWS },
    });

    hzs.router.get("/metrics", root.handler.metricz, .{});

    if (hzs.provider) |p| {
        container.authProvider = p;
        // hzs.registerRefresherThread(p);
    }

    return hzs;
}

pub fn Run(self: *Self) !Thread {
    return try self.http.listenInNewThread();
}

pub fn Shutdown(self: *Self) void {
    self.container.log.info("server shutting down");
    // recursively deallocate all resources
    // self.refresherThread.join();

    self.container.destroy();

    self.http.deinit();

    self.http.stop();
}

fn loadAuthProviderConfig(self: *Self) anyerror!?*authProvider {
    var provider: ?*authProvider = undefined;

    const authMode = self.container.config.getOrDefault("AUTH_MODE", "");
    if (std.mem.eql(u8, authMode, "")) {
        self.container.log.info("no authentication mode found and disabled.");
        return null;
    }

    const mode = std.meta.stringToEnum(AuthMode, authMode) orelse AuthMode.None;

    switch (mode) {
        .APIKey => {
            const keyConfig = self.container.config.getOrDefault("AUTH_API_KEYS", "");
            if (std.mem.eql(u8, keyConfig, "")) {
                self.container.log.info("auth api keys are empty. authentication is disabled.");
                return null;
            }

            var keys = std.StringHashMap([]const u8).init(self.container.allocator);
            var encodedKeys = std.mem.splitAny(u8, keyConfig, ",");

            while (encodedKeys.next()) |key| {
                var scalerKey: []u8 = undefined;
                scalerKey = try self.container.allocator.alloc(u8, key.len);
                _ = std.mem.replace(u8, key, " ", "", scalerKey[0..key.len]);

                try keys.put(scalerKey, "");
            }

            provider = try authProvider.create(self.container, .APIKey);
            provider.?.keys = keys;

            self.container.log.info("auth APIKey initialized");

            return provider;
        },
        .OAuth => {
            const jwksUrl = self.container.config.getOrDefault("AUTH_JWKS_URL", "");
            if (std.mem.eql(u8, jwksUrl, "")) {
                self.container.log.info("auth jwks url is empty. authentication is disabled.");
                return null;
            }

            const refreshInterval = self.container.config.getOrDefault("AUTH_REFRESH_INTERVAL", "");
            if (std.mem.eql(u8, refreshInterval, "")) {
                self.container.log.info("auth jwks url is empty. authentication is disabled.");
                return null;
            }

            const refreshAt = try std.fmt.parseInt(i16, refreshInterval, 10);

            provider = try authProvider.create(self.container, .OAuth);
            provider.?.mutex = .{};
            provider.?.pathUrl = jwksUrl;
            provider.?.refreshInterval = refreshAt;
            provider.?.pubKeys = std.StringHashMap(PubKey).init(self.container.allocator);

            self.container.log.info("auth oauth initialized");

            return provider;
        },
        .Basic => {
            const keyConfig = self.container.config.getOrDefault("AUTH_KEYS", "");
            if (std.mem.eql(u8, keyConfig, "")) {
                self.container.log.info("auth credentials are empty. authentication is disabled.");
                return null;
            }

            var keys = std.StringHashMap([]const u8).init(self.container.allocator);

            var encodedKeys = std.mem.splitAny(u8, keyConfig, ",");

            while (encodedKeys.next()) |key| {
                var payload: []u8 = undefined;
                payload = self.container.allocator.alloc(u8, 1024) catch unreachable;

                const codecs = std.base64.standard;
                try codecs.Decoder.decode(payload, key);

                var splitValues = std.mem.splitAny(u8, payload, ":");

                var index: i8 = 0;
                var configKey: []const u8 = undefined;
                var configPassword: []const u8 = undefined;
                while (splitValues.next()) |value| {
                    if (index == 1) {
                        configPassword = try self.container.allocator.alloc(u8, value.len);
                        configPassword = value;
                        break;
                    }
                    configKey = try self.container.allocator.alloc(u8, value.len);
                    configKey = value;
                    index += 1;
                }

                try keys.put(configKey, configPassword);
            }

            provider = try authProvider.create(self.container, .Basic);
            provider.?.keys = keys;

            self.container.log.info("auth basic initialized");

            return provider;
        },
        else => {
            self.container.log.info("no valid auth mode found and disabled.");

            return null;
        },
    }
}

fn registerRefresherThread(self: *Self, provider: *authProvider) !void {
    switch (provider.mode) {
        .OAuth => {
            self.refresherThread = Thread.spawn(.{}, authProvider.refreshKeys, .{provider}) catch |err| {
                self.container.log.any(err);
                return;
            };
        },
        else => {
            // do nothing
        },
    }
}
