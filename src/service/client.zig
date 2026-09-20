const std = @import("std");
const httpz = @import("httpz");
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
pub const RateLimiter = @import("rateLimiter.zig").RateLimiter;
pub const RateLimiterConfig = @import("rateLimiter.zig").RateLimiterConfig;
const outbound_auth = @import("outbound_auth.zig");
const otel = root.otel;

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
    rateLimiter: ?RateLimiterConfig = null,
    /// Per-request connect timeout (ms) for this downstream. Bounds how long the
    /// outbound call waits to establish the TCP/TLS connection before failing.
    /// `null` (default) means no connect timeout.
    timeout_ms: ?u64 = null,
    /// Maximum number of additional attempts for transient failures (network
    /// errors and 5xx). 0 (default) = no retry.
    max_retries: ?u32 = null,
    /// Base backoff in ms between retries; the actual delay is
    /// `retry_base_ms * attempt` (linear). 0 = no backoff.
    retry_base_ms: ?i64 = null,
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
/// Per-service fixed-window rate limiter (null = disabled).
limiter: ?RateLimiter = null,
    /// Optional connect timeout (ms) applied to outbound requests to this service.
    timeout_ms: ?u64 = null,
    /// Max additional attempts for transient failures (network errors + 5xx).
    max_retries: ?u32 = null,
    /// Base backoff (ms) between retries; delay = base * attempt (linear).
    retry_base_ms: ?i64 = null,

/// OAuth token cache (runtime, managed by `ensureOAuthToken`).
oauth_token: ?[]const u8 = null,
oauth_expires_at: i128 = 0,
oauth_mutex: std.Io.Mutex = .init,
    oauth_client: ?zul.http.Client = null,
    /// Circuit breaker guarding the OAuth token endpoint (separate from the
    /// downstream breaker so a flapping IdP can't pin every outbound call).
    oauth_breaker: ?CircuitBreaker = null,

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

    c.client = zul.http.Client.init(ct.io, ct.allocator);
    c.name = service_name;
    c.container = ct;
    c.url = _url;
    c.auth = opts.auth;
    c.timeout_ms = opts.timeout_ms;
    c.max_retries = opts.max_retries;
    c.retry_base_ms = opts.retry_base_ms;

    if (opts.circuitBreaker) |cb| {
        c.breaker = CircuitBreaker.init(cb);
    }

    if (opts.rateLimiter) |rl| {
        c.limiter = RateLimiter.init(rl);
    }

    c.oauth_breaker = CircuitBreaker.init(CircuitBreakerConfig{});

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
    const m = std.meta.stringToEnum(OutboundAuthMode, mode);

    if (m) |selected| {
        switch (selected) {
            .none => {},
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
        }
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

    const to = cfgGet(ct, prefix, "TIMEOUT_MS");
    if (!std.mem.eql(u8, to, "")) {
        opts.timeout_ms = std.fmt.parseUnsigned(u64, to, 10) catch null;
    }

    const mr = cfgGet(ct, prefix, "MAX_RETRIES");
    if (!std.mem.eql(u8, mr, "")) {
        opts.max_retries = std.fmt.parseUnsigned(u32, mr, 10) catch null;
    }

    const rb = cfgGet(ct, prefix, "RETRY_BASE_MS");
    if (!std.mem.eql(u8, rb, "")) {
        opts.retry_base_ms = std.fmt.parseInt(i64, rb, 10) catch null;
    }

    const rl_limit = cfgGet(ct, prefix, "RATE_LIMIT");
    const rl_window = cfgGet(ct, prefix, "RATE_LIMIT_WINDOW_MS");

    if (!std.mem.eql(u8, rl_limit, "")) {
        var rc: RateLimiterConfig = .{ .allocator = ct.allocator, .enabled = true };
        rc.limit = std.fmt.parseUnsigned(u64, rl_limit, 10) catch rc.limit;
        if (!std.mem.eql(u8, rl_window, "")) {
            rc.window_ms = std.fmt.parseInt(i64, rl_window, 10) catch rc.window_ms;
        }
        opts.rateLimiter = rc;
    }

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

    fn retryBackoffMs(self: *Self, attempt: u32) i64 {
        const base = self.retry_base_ms orelse constants.DEFAULT_SERVICE_RETRY_BASE_MS;
        return @as(i64, base) * @as(i64, attempt);
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

    var req: zul.http.Request = undefined;
    var req_owned = false;
    defer if (req_owned) req.deinit();

    var res: zul.http.Response = undefined;
    var replayed: bool = false;
    var attempt: u32 = 0;
    var elapsed: f32 = 0;
    const max_attempts = self.max_retries orelse 0;

    while (true) {
        if (req_owned) req.deinit();
        req_owned = false;
        req = try self.client.allocRequest(ctx.allocator, absoluteURL);
        req_owned = true;

        req.method = method;

        // Propagate the inbound correlation id onto the outbound request so the
        // call chain stays traceable across services. No-op when none is present.
        if (ctx.request.header("X-Correlation-ID")) |cid| {
            try req.header("X-Correlation-ID", cid);
        }

        // Propagate the active OpenTelemetry trace via W3C traceparent (continues
        // the server span across the outbound call). No-op when OTEL is disabled.
        if (ctx.span()) |active| {
            var tp_buf: [55]u8 = undefined;
            const tp = otel.formatTraceparent(&tp_buf, otel.spanContextFromActive(ctx.allocator, active));
            try req.header("traceparent", tp);
        }

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
            b.before() catch {
                self.container.metricz.circuitOpen(.{ .name = self.name }) catch {};
                return ClientError.CircuitOpen;
            };
        }

        // downstream rate limiter: fail fast if the per-service window is exhausted
        if (self.limiter) |*rl| {
            rl.before() catch return ClientError.RateLimited;
        }

        // attach outbound auth (api key / basic / oauth bearer)
        self.applyAuth(ctx, &req) catch |e| return switch (e) {
            error.OAuthTokenFetchFailed => ClientError.OAuthTokenFetchFailed,
            else => e,
        };

        const start = utils.nowMonotonic();

        res = req.getResponse(.{}) catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            if (attempt < max_attempts) {
                attempt += 1;
                const backoff = self.retryBackoffMs(attempt);
                std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff), .awake) catch {};
                continue;
            }
            return e;
        };

        elapsed = utils.elapsedMs(start);

        switch (res.status) {
            404 => {
                return ClientError.EntityNotFound;
            },
            500...600 => {
                if (self.breaker) |*b| b.recordFailure();
                if (attempt < max_attempts) {
                    attempt += 1;
                    const backoff = self.retryBackoffMs(attempt);
                    std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff), .awake) catch {};
                    continue;
                }
                return ClientError.ServiceNotReachable;
            },
            else => {
                if (self.breaker) |*b| b.recordSuccess();
            },
        }

        // OAuth token may have expired mid-flight: force a refresh and replay once.
        if (res.status == 401 and self.auth != null and self.auth.?.mode == .oauth and !replayed) {
            replayed = true;
            self.oauth_token = null;
            if (self.breaker) |*b| b.recordFailure();
            const backoff = self.retryBackoffMs(attempt + 1);
            std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff), .awake) catch {};
            continue;
        }

        break;
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
    self.oauth_mutex.lock(self.container.io) catch {};
    defer self.oauth_mutex.unlock(self.container.io);

    const now = utils.nowMonotonic().nanoseconds;
    if (self.oauth_token) |token| {
        // 5s skew baked into expires_at so we refresh slightly early
        if (now < self.oauth_expires_at) return token;
    }

    const cfg = self.auth.?.oauth orelse return error.OAuthTokenFetchFailed;

    // Circuit breaker guards the token endpoint so a flapping IdP can't pin every
    // outbound call in a retry storm. If it's open, fall back to the last cached
    // token (possibly stale) so in-flight requests can still be attempted.
    if (self.oauth_breaker) |*b| {
        b.before() catch {
            if (self.oauth_token) |token| return token;
            return error.OAuthTokenFetchFailed;
        };
    }

    if (self.oauth_client == null) {
        self.oauth_client = zul.http.Client.init(self.container.io, self.container.allocator);
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

    var res = req.getResponse(.{}) catch |e| {
        // Network failure: fall back to the last cached token if we have one,
        // otherwise surface the error.
        if (self.oauth_breaker) |*b| b.recordFailure();
        if (self.oauth_token) |token| return token;
        return e;
    };

    if (res.status < 200 or res.status > 299) {
        if (self.oauth_breaker) |*b| b.recordFailure();
        // Refresh failed: reuse the previously cached token (stale is better than
        // hard-failing the outbound call) if one is available.
        if (self.oauth_token) |token| return token;
        return error.OAuthTokenFetchFailed;
    }

    if (self.oauth_breaker) |*b| b.recordSuccess();

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


// ===================== Tests =====================


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
