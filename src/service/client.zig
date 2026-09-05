const std = @import("std");
const root = @import("../zero.zig");
const Self = @This();
const Client = @This();

const constants = root.constants;
const Context = root.Context;
const conainer = root.container;
const Responder = root.responder;
const utils = root.utils;
const Headers = std.http.Client.Request.Headers;
const ClientError = root.Error.ClientError;
const zul = root.zul;

const CircuitBreaker = @import("circuit_breaker.zig").CircuitBreaker;
const CircuitBreakerConfig = @import("circuit_breaker.zig").CircuitBreakerConfig;
const outbound_auth = @import("outbound_auth.zig");

pub const OutboundAuth = outbound_auth.OutboundAuth;
pub const OutboundAuthMode = outbound_auth.OutboundAuthMode;
pub const BasicConfig = outbound_auth.BasicConfig;
pub const ApiKeyConfig = outbound_auth.ApiKeyConfig;
pub const OAuthConfig = outbound_auth.OAuthConfig;

/// Per-service configuration supplied to `app.addHttpService`. Explicit values
/// override any `SERVICE_<NAME>_*` env defaults resolved by `fromEnv`.
pub const ServiceOptions = struct {
    auth: ?OutboundAuth = null,
    circuitBreaker: ?CircuitBreakerConfig = null,
};

container: *root.container = undefined,
client: zul.http.Client,
arena: *std.heap.ArenaAllocator,
url: ?[]const u8 = undefined,
name: []const u8 = undefined,

/// Outbound auth to attach to every request (null = none).
auth: ?OutboundAuth = null,
/// Circuit breaker guarding this downstream (null = disabled).
breaker: ?CircuitBreaker = null,

/// OAuth token cache (runtime, managed by `ensureOAuthToken`).
oauth_token: ?[]const u8 = null,
oauth_expires_at: i128 = 0,
oauth_mutex: std.Io.Mutex = .init,
oauth_client: ?zul.http.Client = null,

pub fn create(
    ct: *root.container,
    service_name: []const u8,
    _url: []const u8,
) !*Client {
    return createWithConfig(
        ct,
        service_name,
        _url,
        ServiceOptions{},
    );
}

pub fn createWithConfig(
    ct: *root.container,
    service_name: []const u8,
    _url: []const u8,
    opts: ServiceOptions,
) !*Client {
    const c = try ct.allocator.create(Client);

    c.client = zul.http.Client.init(utils.io, ct.allocator);
    c.name = service_name;
    c.container = ct;
    c.url = _url;
    c.auth = opts.auth;

    if (opts.circuitBreaker) |cb| {
        c.breaker = CircuitBreaker.init(cb);
    }

    return c;
}

pub fn deinit(self: *Self) void {
    if (self.oauth_token) |token| {
        self.container.allocator.free(token);
    }

    if (self.oauth_client) |*c| {
        c.deinit();
    }

    self.client.deinit();
}

/// Resolve per-service auth/circuit-breaker config from `SERVICE_<NAME>_*`
/// env keys (service name uppercased, non-alphanumeric → `_`).
pub fn fromEnv(ct: *root.container, name: []const u8) ServiceOptions {
    var opts: ServiceOptions = .{};

    const prefix = serviceEnvPrefix(ct, name) catch return opts;
    defer ct.allocator.free(prefix);

    const mode = cfgGet(ct, prefix, "AUTH_MODE");
    if (std.mem.eql(u8, mode, "")) return opts;

    const m = std.meta.stringToEnum(OutboundAuthMode, mode) orelse return opts;

    switch (m) {
        .apiKey => {
            const key = cfgGet(ct, prefix, "API_KEY");

            if (!std.mem.eql(u8, key, "")) {
                opts.auth = .{
                    .mode = .apiKey,
                    .apiKey = .{ .key = key },
                };
            }
        },
        .basic => {
            const u = cfgGet(ct, prefix, "BASIC_USER");
            const p = cfgGet(ct, prefix, "BASIC_PASS");

            if (!std.mem.eql(u8, u, "") and !std.mem.eql(u8, p, "")) {
                opts.auth = .{
                    .mode = .basic,
                    .basic = .{ .username = u, .password = p },
                };
            }
        },
        .oauth => {
            const tu = cfgGet(ct, prefix, "OAUTH_TOKEN_URL");
            const cid = cfgGet(ct, prefix, "OAUTH_CLIENT_ID");
            const sec = cfgGet(ct, prefix, "OAUTH_CLIENT_SECRET");

            if (!std.mem.eql(u8, tu, "") and
                !std.mem.eql(u8, cid, "") and
                !std.mem.eql(u8, sec, ""))
            {
                opts.auth = .{ .mode = .oauth, .oauth = .{
                    .tokenUrl = tu,
                    .clientId = cid,
                    .clientSecret = sec,
                    .scope = optCfgGet(ct, prefix, "OAUTH_SCOPE"),
                    .audience = optCfgGet(ct, prefix, "OAUTH_AUDIENCE"),
                } };
            }
        },
        else => {},
    }

    var cb: CircuitBreakerConfig = .{};

    const ft = cfgGet(ct, prefix, "CB_FAILURE_THRESHOLD");
    const cd = cfgGet(ct, prefix, "CB_COOLDOWN_MS");

    if (!std.mem.eql(u8, ft, "")) {
        cb.failure_threshold = std.fmt.parseInt(u32, ft, 10) catch cb.failure_threshold;
    }

    if (!std.mem.eql(u8, cd, "")) {
        cb.cooldown_ms = std.fmt.parseUnsigned(u64, cd, 10) catch cb.cooldown_ms;
    }

    opts.circuitBreaker = cb;

    return opts;
}

fn serviceEnvPrefix(ct: *root.container, name: []const u8) ![]const u8 {
    const prefix = "SERVICE_";
    const buf = try ct.allocator.alloc(u8, prefix.len + name.len);
    @memcpy(buf[0..prefix.len], prefix);

    var i: usize = prefix.len;
    for (name) |ch| {
        const up: u8 = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        buf[i] = if (up == '-' or up == ' ') '_' else up;
        i += 1;
    }

    return buf[0..i];
}

fn cfgGet(ct: *root.container, prefix: []const u8, suffix: []const u8) []const u8 {
    const key = std.fmt.allocPrint(
        ct.allocator,
        "{s}_{s}",
        .{ prefix, suffix },
    ) catch return "";
    defer ct.allocator.free(key);

    return ct.config.getOrDefault(key, "");
}

fn optCfgGet(ct: *root.container, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    const v = cfgGet(ct, prefix, suffix);

    if (std.mem.eql(u8, v, "")) {
        return null;
    }

    return v;
}

pub fn metric(
    self: *Self,
    duration: f32,
    method: []const u8,
    status: u16,
    path: []const u8,
) !void {
    try self.container.metricz.clientResponse(.{
        .method = method,
        .path = path,
        .status = status,
    }, duration);
}

pub fn log(
    _: *Self,
    ctx: *Context,
    traceId: []const u8,
    duration: f32,
    method: []const u8,
    status: u16,
    path: []const u8,
) !void {
    var buffer: []u8 = undefined;
    buffer = try ctx.allocator.alloc(u8, 200);
    buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ traceId, status, duration, method, path });
    ctx.info(buffer);
}

pub fn get(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.GET,
        path,
        queryParams,
        headers,
        null,
        response,
    );
}

pub fn post(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.POST,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

pub fn put(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.PUT,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

pub fn delete(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.DELETE,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

fn createAndSendRequest(
    self: *Self,
    ctx: *Context,
    method: std.http.Method,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
    comptime response: type,
) !?response {
    var absoluteURL = self.url.?;
    defer ctx.allocator.destroy(&absoluteURL);

    if (path.len > 0) {
        absoluteURL = try utils.combine(
            ctx.allocator,
            "{s}{s}",
            .{ self.url.?, path },
        );
    }

    var req = try self.client.allocRequest(ctx.allocator, absoluteURL);
    defer req.deinit();

    req.method = method;

    if (queryParams) |params| {
        var iterator = params.iterator();
        while (iterator.next()) |param| {
            try req.query(param.key_ptr.*, param.value_ptr.*);
        }
    }

    if (headers) |custom_headers| {
        var iterator = custom_headers.iterator();
        while (iterator.next()) |header| {
            try req.header(header.key_ptr.*, header.value_ptr.*);
        }
    }

    if (payload) |body| {
        req.body(body);
    }

    // circuit breaker: fail fast if open
    if (self.breaker) |*b| {
        b.before() catch return ClientError.CircuitOpen;
    }

    // attach outbound auth (api key / basic / oauth bearer)
    self.applyAuth(ctx, &req) catch |e| return switch (e) {
        error.OAuthTokenFetchFailed => ClientError.OAuthTokenFetchFailed,
        else => e,
    };

    const start = utils.nowMonotonic();

    var res = req.getResponse(.{}) catch |e| {
        if (self.breaker) |*b| b.recordFailure();
        return e;
    };

    const elapsed: f32 = utils.elapsedMs(start);

    switch (res.status) { //expand more
        404 => {
            return ClientError.EntityNotFound;
        },
        500...600 => {
            if (self.breaker) |*b| b.recordFailure();
            return ClientError.ServiceNotReachable;
        },
        else => {
            if (self.breaker) |*b| b.recordSuccess();
        },
    }

    const responseTraceID = res.header("X-Correlation-ID");
    var traceID = try self.getResponseTraceIDBuffer(ctx.allocator);
    defer ctx.allocator.destroy(&traceID);
    if (responseTraceID) |_id| {
        traceID = _id;
    }

    const parsed = try res.json(
        response,
        ctx.allocator,
        .{},
    );
    defer parsed.deinit();

    try self.metric(
        elapsed,
        @tagName(method),
        res.status,
        absoluteURL,
    );

    try self.log(
        ctx,
        traceID,
        elapsed,
        @tagName(method),
        res.status,
        absoluteURL,
    );

    return parsed.value;
}

fn applyAuth(self: *Self, ctx: *Context, req: *zul.http.Request) !void {
    if (self.auth == null) return;

    if (self.auth.?.mode == .oauth) {
        const token = try self.ensureOAuthToken();
        const value = try std.fmt.allocPrint(
            ctx.allocator,
            "Bearer {s}",
            .{token},
        );

        try req.header("authorization", value);

        return;
    }

    if (try OutboundAuth.buildHeader(self.auth.?, ctx.allocator)) |h| {
        try req.header(h.name, h.value);
    }
}

fn ensureOAuthToken(self: *Self) ![]const u8 {
    self.oauth_mutex.lock(utils.io) catch {};
    defer self.oauth_mutex.unlock(utils.io);

    const now = utils.nowMonotonic().nanoseconds;
    if (self.oauth_token) |token| {
        // 5s skew baked into expires_at so we refresh slightly early
        if (now < self.oauth_expires_at) return token;
    }

    const cfg = self.auth.?.oauth orelse return error.OAuthTokenFetchFailed;

    if (self.oauth_client == null) {
        self.oauth_client = zul.http.Client.init(utils.io, self.container.allocator);
    }
    const token_client = &self.oauth_client.?;

    var req = try token_client.allocRequest(
        self.container.allocator,
        cfg.tokenUrl,
    );
    defer req.deinit();

    req.method = std.http.Method.POST;

    const creds = try std.fmt.allocPrint(
        self.container.allocator,
        "{s}:{s}",
        .{ cfg.clientId, cfg.clientSecret },
    );
    defer self.container.allocator.free(creds);

    const creds_b64_len = std.base64.standard.Encoder.calcSize(creds.len);
    const creds_b64 = try self.container.allocator.alloc(u8, creds_b64_len);
    defer self.container.allocator.free(creds_b64);

    _ = std.base64.standard.Encoder.encode(creds_b64, creds);
    const authz = try std.fmt.allocPrint(
        self.container.allocator,
        "Basic {s}",
        .{creds_b64},
    );
    defer self.container.allocator.free(authz);

    try req.header("authorization", authz);
    try req.header("content-type", "application/x-www-form-urlencoded");

    var body = std.array_list.Managed(u8).init(self.container.allocator);
    defer body.deinit();

    try body.appendSlice("grant_type=client_credentials");
    try body.appendSlice("&client_id=");
    try body.appendSlice(cfg.clientId);

    try body.appendSlice("&client_secret=");
    try body.appendSlice(cfg.clientSecret);

    if (cfg.scope) |s| {
        try body.appendSlice("&scope=");
        try body.appendSlice(s);
    }

    if (cfg.audience) |a| {
        try body.appendSlice("&audience=");
        try body.appendSlice(a);
    }

    req.body(body.items);

    var res = try req.getResponse(.{});
    if (res.status < 200 or res.status > 299) {
        return error.OAuthTokenFetchFailed;
    }

    const TokenResponse = struct {
        access_token: []const u8,
        token_type: ?[]const u8,
        expires_in: ?u64,
        refresh_token: ?[]const u8,
        scope: ?[]const u8,
    };

    const parsed = try res.json(
        TokenResponse,
        self.container.allocator,
        .{},
    );
    defer parsed.deinit();

    const token = parsed.value.access_token;
    const expires_in = parsed.value.expires_in orelse 3600;

    if (self.oauth_token) |old| {
        self.container.allocator.free(old);
    }

    const owned = try self.container.allocator.dupe(u8, token);
    self.oauth_token = owned;
    self.oauth_expires_at = now + (@as(i128, expires_in) * 1_000_000_000) - (5_000 * 1_000_000);

    return owned;
}

fn getResponseTraceIDBuffer(_: *Self, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s:>36}", .{" "});
}
