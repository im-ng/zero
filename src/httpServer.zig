const std = @import("std");
const root = @import("zero.zig");
const Thread = std.Thread;
const httpz = root.httpz;
const constants = root.constants;
const Context = root.Context;
const tracz_mw = root.tracz;
const cors_mw = root.httpz.middleware.Cors;
const auth_mw = root.authz;
const rbac_mw = root.rbac;
const utils = root.utils;
const ws_mw = root.WSMiddleware;
const rateLimiter_mw = root.rateLimiter;

const server = @This();
const Self = @This();

const decode = std.base64.Base64Decoder;

const authProvider = root.AuthProvider;
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
provider: ?*root.AuthProvider = undefined,
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

    // Inbound request timeout: a stalled client must not pin a worker forever.
    // httpz defaults to effectively-infinite, so cap it (override via config).
    const default_request_timeout_ms: u32 = 30000;
    const request_timeout_ms: u32 = blk: {
        const v = hzs.container.config.getOrDefault("ZERO_REQUEST_TIMEOUT_MS", "");
        break :blk std.fmt.parseInt(u32, v, 10) catch default_request_timeout_ms;
    };

    hzs.handler = root.handler.Handler{
        .container = hzs.container,
    };

    // Inbound bulkhead: cap concurrent requests (0 = unlimited). Override with
    // INBOUND_MAX_CONCURRENT (e.g. 100). Rejected requests get a 503.
    hzs.handler.in_flight = std.atomic.Value(u32).init(0);
    hzs.handler.max_concurrent = parseMaxConcurrent(hzs.container.config);

    // httpz pre-allocates `large_buffer_count` request-body buffers of
    // `large_buffer_size`. When `workers.large_buffer_size` is unset it defaults
    // to `request.max_body_size` (32MiB here), giving 16 × 32MiB ≈ 512MiB of
    // resident memory for the whole process lifetime. Cap the pool explicitly so
    // steady-state RSS stays small; bodies larger than the pooled buffer still
    // grow on the per-request arena and are freed at request end. Override via
    // ZERO_HTTP_LARGE_BUFFER_SIZE (bytes) / ZERO_HTTP_LARGE_BUFFER_COUNT.
    const large_buffer_size: u32 = blk: {
        const v = hzs.container.config.getAsInt("ZERO_HTTP_LARGE_BUFFER_SIZE") catch 0;
        break :blk if (v == 0) 1 * 1024 * 1024 else @as(u32, v);
    };
    const large_buffer_count: u16 = blk: {
        const v = hzs.container.config.getAsInt("ZERO_HTTP_LARGE_BUFFER_COUNT") catch 0;
        break :blk if (v == 0) 16 else v;
    };

    hzs.http = try httpz.Server(*root.handler.Handler).init(
        utils.io,
        hzs.container.allocator,
        .{
            .address = httpz.Config.Address.all(hzs.port),
            .request = .{
                .max_multiform_count = 32,
                .max_body_size = 32 * 1024 * 1024,
            },
            .workers = .{
                .large_buffer_size = large_buffer_size,
                .large_buffer_count = large_buffer_count,
            },
            .timeout = .{ .request = request_timeout_ms },
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

    const rbacMW = try hzs.http.middleware(rbac_mw, .{
        .allocator = allocator,
        .container = hzs.container,
        .rbac = hzs.container.rbac,
    });

    const mwWS = try hzs.http.middleware(ws_mw, .{
        .allocator = allocator,
        .container = container,
    });

    // Rate limiter is ON by default; set RATE_LIMIT_ENABLE=false to disable it.
    // (In-memory limiter; a distributed store would be configured later.)
    const rlEnabled = blk: {
        const v = hzs.container.config.getOrDefault("RATE_LIMIT_ENABLE", "");
        break :blk !std.mem.eql(u8, v, "false");
    };
    var rlKeyMode: rateLimiter_mw.KeyMode = .ip;
    var rlHeaderName: []const u8 = "X-Forwarded-For";
    const rlKey = hzs.container.config.getOrDefault("RATE_LIMIT_KEY", "ip");
    if (std.mem.startsWith(u8, rlKey, "header:")) {
        rlKeyMode = .header;
        rlHeaderName = rlKey["header:".len..];
    }
    // `getAsInt` returns 0 for a missing key (it never errors), so `catch` alone
    // won't apply the default. Treat 0 as "use default".
    const rlMaxRaw = hzs.container.config.getAsInt("RATE_LIMIT_MAX") catch 0;
    const rlMax: u64 = if (rlMaxRaw == 0) 100 else rlMaxRaw;
    const rlWindowRaw = hzs.container.config.getAsInt("RATE_LIMIT_WINDOW") catch 0;
    const rlWindowS: i64 = if (rlWindowRaw == 0) 60 else rlWindowRaw;
    const rateLimitMW = try hzs.http.middleware(rateLimiter_mw, .{
        .allocator = allocator,
        .enabled = rlEnabled,
        .limit = rlMax,
        .window_ms = @as(i64, rlWindowS) * 1000,
        .key_mode = rlKeyMode,
        .header_name = rlHeaderName,
    });

    hzs.router = try hzs.http.router(.{
        .middlewares = &.{ rateLimitMW, traczMW, corsMW, authMW, rbacMW, mwWS },
    });

    if (hzs.provider) |p| {
        container.authProvider = p;
        // hzs.registerRefresherThread(p);
    }

    return hzs;
}

pub fn run(self: *Self) !Thread {
    return try self.http.listenInNewThread();
}

pub fn shutdown(self: *Self) void {
    self.container.log.info("server shutting down");
    // recursively deallocate all resources
    // self.refresherThread.join();

    // NOTE: the container and pub/sub clients are torn down by App.run() once
    // the server thread has stopped. Destroying them here (from a signal
    // handler) would free client state while their background threads (e.g.
    // the NATS io_task) are still running, which both hangs process exit and
    // risks a use-after-free.
    self.http.stop();

    self.http.deinit();
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
            provider.?.mutex = .init;
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

/// Reads `INBOUND_MAX_CONCURRENT` from config; 0 (or unparsable) means unlimited.
fn parseMaxConcurrent(config: *root.config) u32 {
    const v = config.getOrDefault("INBOUND_MAX_CONCURRENT", "0");
    return std.fmt.parseInt(u32, v, 10) catch 0;
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
