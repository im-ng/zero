const std = @import("std");
const root = @import("../zero.zig");
const request = root.httpz.request;

const AuthProvider = @This();
const Self = @This();
const utils = root.utils;
const Context = root.Context;
const ClientError = root.Error.ClientError;
const jwt = root.jwt;

pub const BasicAuthMode = "Basic";
pub const ApiKeyAuthMode = "ApiKey";
pub const OAuthAuthMode = "OAuth";

/// JWKS refresh resilience: base interval between successful refreshes and the
/// cap on exponential backoff after consecutive failures, so a dead IdP is not
/// stampeded by the refresh cron or by failed token validations.
const jwks_min_interval_ms: i128 = 30_000;
const jwks_max_backoff_ms: i128 = 300_000;

/// Exponential backoff (capped) before retrying a failed JWKS fetch.
fn jwksRetryDelayMs(failures: u32) i128 {
    const shift = @min(failures, 5);
    return @min(jwks_max_backoff_ms, jwks_min_interval_ms * (@as(i128, 1) << @intCast(shift)));
}

pub const AuthMode = enum {
    Basic,
    APIKey,
    OAuth,
    None,

    pub fn str(self: AuthMode) [:0]const u8 {
        return switch (self) {
            .Basic => "Basic",
            .APIKey => "APIKey",
            .OAuth => "OAuth",
            .None => "None",
        };
    }
};

pub const publiKey = struct {
    kid: []const u8,
    kty: []const u8,
    use: []const u8,
    n: []const u8,
    e: []const u8,
    alg: []const u8,
};

pub const publicKeys = struct {
    keys: []publiKey,
};

pub const jwtClaims = struct {
    // Claims are made optional because real IdP tokens (Keycloak, Google, …)
    // routinely omit some of them — Keycloak access tokens, for example, do not
    // include `nbf`, and `jti`/`aud` vary by issuer. `getClaimsT` treats a
    // missing non-optional field as a hard parse error, which surfaced as
    // `TokenInvalidClaims` for every valid token. Optional fields default to
    // null and the caller sees only the claims that were actually present.
    iss: ?[]const u8 = null,
    iat: ?u64 = null,
    exp: ?u64 = null,
    aud: ?[]const u8 = null,
    sub: ?[]const u8 = null,
    jti: ?[]const u8 = null,
    nbf: ?u64 = null,
    /// optional RBAC role claim; absent in a token leaves this empty
    role: []const u8 = "",
};

pub const AuthError = error{
    MissingAuthHeader,
    InvalidAuthKeyHeader,
    InvalidAuthAPIHeader,
    InvalidCredentials,
    NoSpaceLeft,
    OutOfMemory,
    InvalidCharacter,
    InvalidPadding,
    InvalidAuthToken,
    TokenInvalidClaims,
};

const codecs = std.base64.standard;
const Decoder = codecs.Decoder;
const ClientResponse = root.zul.http.client;

mode: AuthMode,
container: *root.container,
keys: std.StringHashMap([]const u8) = undefined,
pubKeys: std.StringHashMap(publiKey) = undefined,
refreshThread: std.Thread = undefined,
mutex: std.Io.Mutex = undefined,
refreshInterval: i16 = 60, // seconds
pathUrl: []const u8 = undefined,

/// When set, OAuth tokens must carry this `aud` (audience) claim. Optional so
/// existing deployments without it are unaffected. Wired from `OAUTH_AUDIENCE`.
expected_audience: ?[]const u8 = null,
/// When set, OAuth tokens must be issued by this `iss` (issuer). Optional.
/// Wired from `OAUTH_ISSUER`.
expected_issuer: ?[]const u8 = null,

/// JWKS refresh bookkeeping for surge protection. `last_refresh_ms` is the
/// monotonic timestamp (ms) of the last attempt; `refresh_failures` counts
/// consecutive failures; `last_refresh_ok` records the last outcome so the
/// health check can report JWKS freshness.
last_refresh_ms: i128 = 0,
refresh_failures: u32 = 0,
last_refresh_ok: bool = true,

pub fn create(c: *root.container, m: AuthMode) anyerror!*AuthProvider {
    const auth = try c.allocator.create(AuthProvider);
    errdefer c.allocator.destroy(c);
    auth.* = .{ .container = c, .mode = m };
    return auth;
}

/// Constant-time equality for two byte slices (content; length must match).
/// Avoids leaking the secret via timing side-channels.
fn constTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }

    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }

    return diff == 0;
}

/// Extract the credential token from an auth header.
fn authToken(header: []const u8) ?[]const u8 {
    var token: ?[]const u8 = null;
    var parts = std.mem.splitAny(u8, header, " \t");
    while (parts.next()) |value| {
        if (value.len > 0) {
            token = value;
        }
    }
    return token;
}

/// Look up a credential in the configured KV store under `prefix ++ key`.
/// Returns an allocator-owned copy of the stored value (caller must free) or
/// null when no KV store is configured or the lookup fails. Used to augment the
/// static in-memory `keys` map so credentials can live in Redis/etcd/etc.
fn kvLookup(self: *Self, ctx: *root.Context, prefix: []const u8, key: []const u8) ?[]const u8 {
    const kv = self.container.defaultKV orelse return null;
    const full = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, key }) catch return null;
    defer ctx.allocator.free(full);
    return kv.get(ctx, full) catch null;
}

pub fn validateBasicAuth(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8, ctx: ?*root.Context) AuthError!void {
    const token = authToken(authHeader) orelse return AuthError.InvalidAuthToken;

    const size = try Decoder.calcSizeForSlice(token);

    var decoded: []u8 = undefined;
    decoded = try allocator.alloc(u8, size);
    defer allocator.free(decoded);
    try Decoder.decode(decoded, token);

    var values = std.mem.splitAny(u8, decoded, ":");
    var headerKey: []const u8 = undefined;
    var headerPassword: []const u8 = undefined;

    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            headerPassword = value;
            break;
        }
        headerKey = value;
        index += 1;
    }

    // Static (in-memory) keys map is the first authority.
    if (self.keys.contains(headerKey)) {
        if (self.keys.get(headerKey)) |value| {
            // Constant-time comparison to avoid leaking the password via timing.
            if (constTimeEql(value, headerPassword)) {
                return;
            }
        }
        return AuthError.InvalidCredentials;
    }

    // KV augmentation: a username absent from the static map is still valid if it
    // exists in the configured KV store (e.g. Redis) with a matching password,
    // so operators can rotate credentials without a restart.
    if (ctx) |c| {
        if (self.kvLookup(c, "auth:basic:", headerKey)) |stored| {
            defer allocator.free(stored);
            if (constTimeEql(stored, headerPassword)) {
                return;
            }
            return AuthError.InvalidCredentials;
        }
    }

    return AuthError.InvalidAuthKeyHeader;
}

pub fn validateAPIKeyAuth(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8, ctx: ?*root.Context) AuthError!void {
    const token = authToken(authHeader) orelse return AuthError.InvalidAuthToken;

    // Static (in-memory) keys map is the first authority.
    if (self.keys.contains(token)) {
        return;
    }

    // KV augmentation: a key absent from the static map is still valid if it
    // exists in the configured KV store (e.g. Redis).
    if (ctx) |c| {
        if (self.kvLookup(c, "auth:apikey:", token)) |stored| {
            allocator.free(stored);
            return;
        }
    }

    return AuthError.InvalidAuthAPIHeader;
}

pub fn validateOAuthToken(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!void {
    const token = authToken(authHeader) orelse return AuthError.InvalidAuthToken;

    // split and identify the token key id
    var jwtTokenizer = jwt.Token.init(allocator);
    jwtTokenizer.parse(token);
    defer jwtTokenizer.deinit();

    const jwtHeader = jwtTokenizer.getHeaders() catch |err| switch (err) {
        else => {
            return AuthError.InvalidAuthToken;
        },
    };
    defer jwtHeader.deinit();

    var kid: []const u8 = undefined;
    if (jwtHeader.value.object.get("kid")) |k| {
        kid = k.string;
    }

    var kidFound: bool = false;
    var publicKey: *publiKey = undefined;
    var iterator = self.pubKeys.iterator();
    while (iterator.next()) |pk| {
        if (std.mem.eql(u8, kid, pk.key_ptr.*)) {
            kidFound = true;
            publicKey = pk.value_ptr;
            break;
        }
    }

    if (kidFound == false) {
        self.container.log.Err(self.container.allocator, "oauth validate: kid not found in pubKeys");
        return AuthError.TokenInvalidClaims;
    }

    const claims = jwtTokenizer.getClaims() catch {
        self.container.log.Err(self.container.allocator, "oauth validate: getClaims failed");
        return AuthError.TokenInvalidClaims;
    };
    defer claims.deinit();

    var validator = jwt.Validator.init(allocator, &jwtTokenizer) catch {
        self.container.log.Err(self.container.allocator, "oauth validate: validator init failed");
        return AuthError.TokenInvalidClaims;
    };
    defer validator.deinit();

    const now = @as(i64, @intCast(@divFloor(utils.nowReal().nanoseconds, 1_000_000_000)));
    // validator.hasBeenIssuedBy(publicKey.) // iss
    // validator.isRelatedTo("sub") // sub
    // validator.isIdentifiedBy("jti rrr") // jti
    // validator.isPermittedFor("example.com") // audience
    // validator.hasBeenIssuedBefore(now) // iat, now is time timestamp
    // validator.isMinimumTimeBefore(now) // nbf, now is time timestamp
    if (validator.isExpired(now)) {
        return AuthError.TokenInvalidClaims;
    }

    // Enforce not-before (nbf): reject tokens that are not yet valid. Safe to
    // always enforce — the validator treats a missing nbf claim as valid.
    if (!validator.isMinimumTimeBefore(now)) {
        return AuthError.TokenInvalidClaims;
    }

    // Enforce audience / issuer only when explicitly configured, so existing
    // deployments that don't set them are unaffected.
    if (self.expected_audience) |aud| {
        if (!validator.isPermittedFor(&[_][]const u8{aud})) {
            return AuthError.TokenInvalidClaims;
        }
    }
    if (self.expected_issuer) |iss| {
        if (!validator.hasBeenIssuedBy(&[_][]const u8{iss})) {
            return AuthError.TokenInvalidClaims;
        }
    }

    return;
}

pub fn retrieveUserName(_: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!?[]const u8 {
    const token = authToken(authHeader) orelse return AuthError.InvalidAuthToken;

    const size = Decoder.calcSizeForSlice(token) catch return AuthError.InvalidPadding;
    const decoded = try allocator.alloc(u8, size);
    defer allocator.free(decoded);
    Decoder.decode(decoded, token) catch return AuthError.InvalidPadding;

    var values = std.mem.splitAny(u8, decoded, ":");
    var headerKey: []const u8 = undefined;
    while (values.next()) |value| {
        headerKey = value;
        break;
    }

    return try allocator.dupe(u8, headerKey);
}

pub fn retrieveClaims(_: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!jwtClaims {
    const token = authToken(authHeader) orelse return AuthError.InvalidAuthToken;

    // split and identify the token key id
    var jwtTokenizer = jwt.Token.init(allocator);
    jwtTokenizer.parse(token);
    defer jwtTokenizer.deinit();

    const claims = jwtTokenizer.getClaimsT(jwtClaims) catch |err| switch (err) {
        else => {
            return AuthError.TokenInvalidClaims;
        },
    };
    defer claims.deinit();

    // return jwtClaims{ .aud = "", .exp = 0, .iat = 0, .iss = "", .jti = "", .nbf = 0, .sub = "" };
    return claims.value;
}

pub fn refreshKeys(ctx: *Context) !void {
    const ap = ctx.container.authProvider;
    const now_ms = @divFloor(utils.nowMonotonic().nanoseconds, 1_000_000);

    // Surge protection: never refresh more often than the base interval, and
    // back off exponentially after consecutive failures. Within the window we
    // keep the last-known-good keys instead of stampeding an unresponsive IdP.
    const since_ms = if (ap.last_refresh_ms == 0) std.math.maxInt(i128) else now_ms - ap.last_refresh_ms;
    const min_interval_ms = if (ap.refresh_failures == 0) jwks_min_interval_ms else jwksRetryDelayMs(ap.refresh_failures);
    if (since_ms < min_interval_ms) {
        return;
    }

    // `ok` is captured by the defer so a successful fetch resets the failure
    // count while any early return below records a failure for the next backoff.
    var ok = false;
    defer {
        ap.last_refresh_ms = now_ms;
        if (ok) {
            ap.refresh_failures = 0;
            ap.last_refresh_ok = true;
        } else {
            ap.refresh_failures += 1;
            ap.last_refresh_ok = false;
        }
    }

    const http = ctx.getService("zero-jwks-service") orelse {
        ctx.err("zero jwks service is not available");
        return ClientError.ServiceNotReachable;
    };

    var req = try http.client.allocRequest(ctx.allocator, http.url.?);
    defer req.deinit();

    req.method = std.http.Method.GET;

    var res = try req.getResponse(.{});
    switch (res.status) { //expand more
        404 => {
            return ClientError.EntityNotFound;
        },
        500...600 => {
            return ClientError.ServiceNotReachable;
        },
        else => {
            // do nothing
        },
    }

    const parsed = try res.json(
        publicKeys,
        ctx.allocator,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    for (parsed.value.keys) |key| {
        ap.mutex.lock(ctx.io) catch {};
        try ap.pubKeys.put(key.kid, key);
        ap.mutex.unlock(ctx.io);
    }

    ok = true;
    ctx.info("oatuh keys refreshed");
}

/// Reports whether the last JWKS refresh succeeded. Wired as a custom health
/// check so Kubernetes can fail the liveness probe when the IdP is unreachable
/// for too long (the refresh cron keeps retrying with backoff in the meantime).
pub fn jwksHealthy(self: *Self) bool {
    return self.last_refresh_ok;
}

// ===================== Tests =====================

test "AuthMode.str returns correct strings" {
    try std.testing.expectEqualStrings("Basic", AuthMode.Basic.str());
    try std.testing.expectEqualStrings("APIKey", AuthMode.APIKey.str());
    try std.testing.expectEqualStrings("OAuth", AuthMode.OAuth.str());
}

test "jwksRetryDelayMs backs off exponentially and caps" {
    // failures == 0 still yields the base interval via the helper.
    try std.testing.expectEqual(jwks_min_interval_ms, jwksRetryDelayMs(0));
    // 1 failure -> 2x base, 3 failures -> 8x base.
    try std.testing.expectEqual(jwks_min_interval_ms * 2, jwksRetryDelayMs(1));
    try std.testing.expectEqual(jwks_min_interval_ms * 8, jwksRetryDelayMs(3));
    // Capped at the max backoff regardless of how many failures have stacked.
    try std.testing.expectEqual(jwks_max_backoff_ms, jwksRetryDelayMs(5));
    try std.testing.expectEqual(jwks_max_backoff_ms, jwksRetryDelayMs(10));
}

test "validateAPIKeyAuth rejects unknown API key" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("my-api-key", "valid");

    var auth = AuthProvider{
        .mode = AuthMode.APIKey,
        .container = undefined,
        .keys = keys,
    };

    const result = auth.validateAPIKeyAuth(allocator, "ApiKey wrong-key", null);
    try std.testing.expectError(AuthError.InvalidAuthAPIHeader, result);
}

test "validateAPIKeyAuth accepts known API key" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("my-api-key", "valid");

    var auth = AuthProvider{
        .mode = AuthMode.APIKey,
        .container = undefined,
        .keys = keys,
    };

    _ = try auth.validateAPIKeyAuth(allocator, "ApiKey my-api-key", null);
    try std.testing.expect(1 == 1);
}

test "validateBasicAuth rejects wrong password" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("user", "correct");

    var auth = AuthProvider{
        .mode = AuthMode.Basic,
        .container = undefined,
        .keys = keys,
    };

    var buf: [64]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&buf, "user:wrong");
    const header = try std.fmt.allocPrint(allocator, "Basic {s}", .{enc});
    defer allocator.free(header);

    try std.testing.expectError(AuthError.InvalidCredentials, auth.validateBasicAuth(allocator, header, null));
}

test "validateBasicAuth accepts correct password" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("user", "correct");

    var auth = AuthProvider{
        .mode = AuthMode.Basic,
        .container = undefined,
        .keys = keys,
    };

    var buf: [64]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&buf, "user:correct");
    const header = try std.fmt.allocPrint(allocator, "Basic {s}", .{enc});
    defer allocator.free(header);

    try auth.validateBasicAuth(allocator, header, null);
}

test "retrieveUserName strips Basic prefix and decodes user" {
    const allocator = std.testing.allocator;

    var auth = AuthProvider{
        .mode = AuthMode.Basic,
        .container = undefined,
        .keys = undefined,
    };

    var buf: [64]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&buf, "alice:secret");
    const header = try std.fmt.allocPrint(allocator, "Basic {s}", .{enc});
    defer allocator.free(header);

    // Decoding the whole "Basic ..." header used to fail with InvalidPadding.
    const user = try auth.retrieveUserName(allocator, header);
    defer if (user) |u| allocator.free(u);
    try std.testing.expectEqualStrings("alice", user.?);
}

test "validateAPIKeyAuth accepts bare key without scheme prefix" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("known-key", "valid");

    var auth = AuthProvider{
        .mode = AuthMode.APIKey,
        .container = undefined,
        .keys = keys,
    };

    // A bare key (no "ApiKey " prefix) is the normal client case. The old
    // `index == 1` logic left `token` unassigned and hashed a wild pointer
    // (GPE). It must now match directly.
    try auth.validateAPIKeyAuth(allocator, "known-key", null);
}

test "validateAPIKeyAuth accepts scheme-prefixed key" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("known-key", "valid");

    var auth = AuthProvider{
        .mode = AuthMode.APIKey,
        .container = undefined,
        .keys = keys,
    };

    try auth.validateAPIKeyAuth(allocator, "ApiKey known-key", null);
}

test "validateAPIKeyAuth rejects unknown bare key" {
    const allocator = std.testing.allocator;
    var keys = std.StringHashMap([]const u8).init(allocator);
    defer keys.deinit();
    try keys.put("known-key", "valid");

    var auth = AuthProvider{
        .mode = AuthMode.APIKey,
        .container = undefined,
        .keys = keys,
    };

    try std.testing.expectError(AuthError.InvalidAuthAPIHeader, auth.validateAPIKeyAuth(allocator, "wrong-key", null));
}

// --- OAuth `aud` / `iss` / expiry enforcement -------------------------------
//
// `validateOAuthToken` checks the `kid`, `exp`, `nbf`, `aud` and `iss` claims
// but (by design) does not cryptographically verify the RSA signature — the
// signature is trusted once the `kid` resolves to a configured JWKS key. So we
// can exercise the claim-enforcement paths with a structurally valid JWT whose
// signature is a dummy. This is exactly what the OAuth `aud` test needs: it
// proves `expected_audience` / `expected_issuer` gating works end-to-end.

fn b64url(alloc: std.mem.Allocator, in: []const u8) ![]u8 {
    const a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < in.len) : (i += 3) {
        const b0 = in[i];
        const b1 = if (i + 1 < in.len) in[i + 1] else 0;
        const b2 = if (i + 2 < in.len) in[i + 2] else 0;
        const n = @as(u32, b0) << 16 | @as(u32, b1) << 8 | @as(u32, b2);
        try out.append(alloc, a[(n >> 18) & 63]);
        try out.append(alloc, a[(n >> 12) & 63]);
        if (i + 1 < in.len) {
            try out.append(alloc, a[(n >> 6) & 63]);
        }
        if (i + 2 < in.len) {
            try out.append(alloc, a[n & 63]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn makeOAuthJwt(
    alloc: std.mem.Allocator,
    aud: []const u8,
    iss: []const u8,
    exp: i64,
    nbf: i64,
) ![]u8 {
    const header = try std.fmt.allocPrint(alloc, "{{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"test-kid\"}}", .{});
    defer alloc.free(header);
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"aud\":\"{s}\",\"iss\":\"{s}\",\"exp\":{d},\"nbf\":{d}}}",
        .{ aud, iss, exp, nbf },
    );
    defer alloc.free(payload);
    const h = try b64url(alloc, header);
    defer alloc.free(h);
    const p = try b64url(alloc, payload);
    defer alloc.free(p);
    return std.fmt.allocPrint(alloc, "{s}.{s}.deadbeef", .{ h, p });
}

fn makeOAuthProvider(alloc: std.mem.Allocator, aud: ?[]const u8, iss: ?[]const u8) !AuthProvider {
    var pub_keys = std.StringHashMap(publiKey).init(alloc);
    try pub_keys.put("test-kid", publiKey{
        .kid = "test-kid",
        .kty = "RSA",
        .use = "sig",
        .n = "",
        .e = "",
        .alg = "RS256",
    });
    return AuthProvider{
        .mode = AuthMode.OAuth,
        .container = undefined,
        .pubKeys = pub_keys,
        .expected_audience = aud,
        .expected_issuer = iss,
    };
}

test "validateOAuthToken accepts token with matching audience and issuer" {
    const alloc = std.testing.allocator;
    var auth = try makeOAuthProvider(alloc, "my-audience", "issuer");
    defer auth.pubKeys.deinit();

    const jwt_str = try makeOAuthJwt(alloc, "my-audience", "issuer", 9999999999, 1);
    defer alloc.free(jwt_str);
    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{jwt_str});
    defer alloc.free(header);

    // No error => audience + issuer + expiry + not-before all accepted.
    try auth.validateOAuthToken(alloc, header);
}

test "validateOAuthToken rejects token with wrong audience" {
    const alloc = std.testing.allocator;
    var auth = try makeOAuthProvider(alloc, "my-audience", "issuer");
    defer auth.pubKeys.deinit();

    const jwt_str = try makeOAuthJwt(alloc, "other-audience", "issuer", 9999999999, 1);
    defer alloc.free(jwt_str);
    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{jwt_str});
    defer alloc.free(header);

    try std.testing.expectError(AuthError.TokenInvalidClaims, auth.validateOAuthToken(alloc, header));
}

test "validateOAuthToken rejects token with wrong issuer" {
    const alloc = std.testing.allocator;
    var auth = try makeOAuthProvider(alloc, "my-audience", "issuer");
    defer auth.pubKeys.deinit();

    const jwt_str = try makeOAuthJwt(alloc, "my-audience", "evil-issuer", 9999999999, 1);
    defer alloc.free(jwt_str);
    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{jwt_str});
    defer alloc.free(header);

    try std.testing.expectError(AuthError.TokenInvalidClaims, auth.validateOAuthToken(alloc, header));
}

test "validateOAuthToken rejects expired token" {
    const alloc = std.testing.allocator;
    var auth = try makeOAuthProvider(alloc, "my-audience", "issuer");
    defer auth.pubKeys.deinit();

    // exp in the past (1s after epoch); nbf also past so not-before passes.
    const jwt_str = try makeOAuthJwt(alloc, "my-audience", "issuer", 1, 1);
    defer alloc.free(jwt_str);
    const header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{jwt_str});
    defer alloc.free(header);

    try std.testing.expectError(AuthError.TokenInvalidClaims, auth.validateOAuthToken(alloc, header));
}
