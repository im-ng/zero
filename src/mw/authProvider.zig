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
    iss: []const u8,
    iat: u64,
    exp: u64,
    aud: []const u8,
    sub: []const u8,
    jti: []const u8,
    nbf: u64,
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

/// Constant-time equality for two byte slices (content; length must match).
/// Avoids leaking the secret via timing side-channels.
fn constTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

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

pub fn create(c: *root.container, m: AuthMode) anyerror!*AuthProvider {
    const auth = try c.allocator.create(AuthProvider);
    errdefer c.allocator.destroy(c);
    auth.* = .{ .container = c, .mode = m };
    return auth;
}

pub fn validateBasicAuth(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!void {
    var values = std.mem.splitAny(u8, authHeader, " ");

    var header: []const u8 = undefined;
    var token: []const u8 = undefined;

    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            token = value;
            break;
        }
        header = value;
        index += 1;
    }

    if (index != 1) {
        return AuthError.InvalidAuthToken;
    }

    const size = try Decoder.calcSizeForSlice(token);

    var decoded: []u8 = undefined;
    decoded = try allocator.alloc(u8, size);
    defer allocator.free(decoded);
    try Decoder.decode(decoded, token);

    values = std.mem.splitAny(u8, decoded, ":");
    var headerKey: []const u8 = undefined;
    var headerPassword: []const u8 = undefined;

    index = 0;
    while (values.next()) |value| {
        if (index == 1) {
            headerPassword = value;
            break;
        }
        headerKey = value;
        index += 1;
    }

    if (self.keys.contains(headerKey) == false) {
        return AuthError.InvalidAuthKeyHeader;
    }

    const storedValue = self.keys.get(headerKey);
    if (storedValue) |value| {
        // Constant-time comparison to avoid leaking the password via timing.
        if (constTimeEql(value, headerPassword)) {
            return;
        }
    }

    return AuthError.InvalidCredentials;
}

pub fn validateAPIKeyAuth(self: *Self, _: std.mem.Allocator, authHeader: []const u8) AuthError!void {
    var values = std.mem.splitAny(u8, authHeader, " ");

    var header: []const u8 = undefined;
    var token: []const u8 = undefined;

    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            token = value;
            break;
        }
        header = value;
        index += 1;
    }

    if (index != 1) {
        return AuthError.InvalidAuthToken;
    }

    if (self.keys.contains(token) == false) {
        return AuthError.InvalidAuthAPIHeader;
    }

    // auth api key matched
    return;
}

pub fn validateOAuthToken(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!void {
    var values = std.mem.splitAny(u8, authHeader, " ");

    var header: []const u8 = undefined;
    var token: []const u8 = undefined;

    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            token = value;
            break;
        }
        header = value;
        index += 1;
    }

    // split and identify the token key id
    var jwtTokenizer = jwt.Token.init(allocator);
    jwtTokenizer.deinit();
    jwtTokenizer.parse(token);

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
        return AuthError.TokenInvalidClaims;
    }

    const claims = jwtTokenizer.getClaims() catch |err| switch (err) {
        else => {
            return AuthError.TokenInvalidClaims;
        },
    };
    defer claims.deinit();

    var validator = jwt.Validator.init(allocator, &jwtTokenizer) catch |err| switch (err) {
        else => {
            return AuthError.TokenInvalidClaims;
        },
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

pub fn retrieveUserName(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!?[]const u8 {
    _ = allocator;
    var decoded: []u8 = undefined;
    decoded = try self.container.allocator.alloc(u8, authHeader.len);
    defer self.container.allocator.free(decoded);

    try Decoder.decode(decoded, authHeader);
    var values = std.mem.splitAny(u8, decoded, ":");

    var headerKey: []const u8 = undefined;

    while (values.next()) |value| {
        headerKey = value;
        break;
    }

    return headerKey;
}

pub fn retrieveClaims(_: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!jwtClaims {
    var values = std.mem.splitAny(u8, authHeader, " ");

    var header: []const u8 = undefined;
    var token: []const u8 = undefined;
    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            token = value;
            break;
        }
        header = value;
        index += 1;
    }

    // split and identify the token key id
    var jwtTokenizer = jwt.Token.init(allocator);
    jwtTokenizer.deinit();
    jwtTokenizer.parse(token);

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
    const service = ctx.getService("zero-jwks-service");
    if (service == null) {
        ctx.err("zero jwks service is not available");
        return;
    }
    const http = service.?;

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

    const parsed = try res.json(publicKeys, ctx.allocator, .{});
    defer parsed.deinit();

    for (parsed.value.keys) |key| {
        ctx.container.authProvider.mutex.lock(ctx.io) catch {};
        try ctx.container.authProvider.pubKeys.put(key.kid, key);
        ctx.container.authProvider.mutex.unlock(ctx.io);
    }

    ctx.info("oatuh keys refreshed");
}

// ===================== Tests =====================

test "AuthMode.str returns correct strings" {
    try std.testing.expectEqualStrings("Basic", AuthMode.Basic.str());
    try std.testing.expectEqualStrings("APIKey", AuthMode.APIKey.str());
    try std.testing.expectEqualStrings("OAuth", AuthMode.OAuth.str());
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

    const result = auth.validateAPIKeyAuth(allocator, "ApiKey wrong-key");
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

    _ = try auth.validateAPIKeyAuth(allocator, "ApiKey my-api-key");
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

    try std.testing.expectError(AuthError.InvalidCredentials, auth.validateBasicAuth(allocator, header));
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

    try auth.validateBasicAuth(allocator, header);
}
