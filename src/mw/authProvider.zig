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

    pub const Modes = [@typeInfo(AuthMode).Enum.fields.len][:0]const u8{
        "Basic",
        "APIKey",
        "OAuth",
    };

    pub fn str(self: AuthMode) [:0]const u8 {
        return Modes[@enumFromInt(self)];
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
};

pub const AuthError = error{
    MissingAuthHeader,
    InvalidAuthKeyHeader,
    InvalidAuthAPIHeader,
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
mutex: std.Thread.Mutex = undefined,

refreshInterval: i16 = 60, // seconds
pathUrl: []const u8 = undefined,

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
            token = try allocator.alloc(u8, value.len);
            token = value;
            break;
        }
        header = try allocator.alloc(u8, value.len);
        header = value;
        index += 1;
    }

    if (index != 1) {
        return AuthError.InvalidAuthToken;
    }

    self.container.log.info(token);
    self.container.log.any(token.len);

    const size = try Decoder.calcSizeForSlice(token);
    self.container.log.any(size);

    var decoded: []u8 = undefined;
    decoded = try allocator.alloc(u8, size);
    try Decoder.decode(decoded, token);

    values = std.mem.splitAny(u8, decoded, ":");
    var headerKey: []const u8 = undefined;
    var headerPassword: []const u8 = undefined;

    index = 0;
    while (values.next()) |value| {
        if (index == 1) {
            headerPassword = try self.container.allocator.alloc(u8, value.len);
            headerPassword = value;
            break;
        }
        headerKey = try self.container.allocator.alloc(u8, value.len);
        headerKey = value;
        index += 1;
    }

    if (self.keys.contains(headerKey) == false) {
        return AuthError.InvalidAuthKeyHeader;
    }

    const storedValue = self.keys.get(headerKey);
    if (storedValue) |value| {
        if (std.mem.eql(u8, value, headerPassword)) {
            return;
        }
    }

    // auth key matched
    return;
}

pub fn validateAPIKeyAuth(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!void {
    var values = std.mem.splitAny(u8, authHeader, " ");

    var header: []const u8 = undefined;
    var token: []const u8 = undefined;

    var index: i8 = 0;
    while (values.next()) |value| {
        if (index == 1) {
            token = try allocator.alloc(u8, value.len);
            token = value;
            break;
        }
        header = try allocator.alloc(u8, value.len);
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
            token = try allocator.alloc(u8, value.len);
            token = value;
            break;
        }
        header = try allocator.alloc(u8, value.len);
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

    var validator = jwt.Validator.init(&jwtTokenizer) catch |err| switch (err) {
        else => {
            return AuthError.TokenInvalidClaims;
        },
    };
    defer validator.deinit();

    const now = std.time.timestamp();
    // validator.hasBeenIssuedBy(publicKey.) // iss
    // validator.isRelatedTo("sub") // sub
    // validator.isIdentifiedBy("jti rrr") // jti
    // validator.isPermittedFor("example.com") // audience
    // validator.hasBeenIssuedBefore(now) // iat, now is time timestamp
    // validator.isMinimumTimeBefore(now) // nbf, now is time timestamp
    if (validator.isExpired(now)) {
        return AuthError.TokenInvalidClaims;
    }

    return;
}

pub fn retrieveUserName(self: *Self, allocator: std.mem.Allocator, authHeader: []const u8) AuthError!?[]const u8 {
    var decoded: []u8 = undefined;
    decoded = try allocator.alloc(u8, authHeader.len);

    try Decoder.decode(decoded, authHeader);
    var values = std.mem.splitAny(u8, decoded, ":");

    var headerKey: []const u8 = undefined;

    while (values.next()) |value| {
        headerKey = try self.container.allocator.alloc(u8, value.len);
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
            token = try allocator.alloc(u8, value.len);
            token = value;
            break;
        }
        header = try allocator.alloc(u8, value.len);
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
        ctx.container.authProvider.mutex.lock();
        try ctx.container.authProvider.pubKeys.put(key.kid, key);
        ctx.container.authProvider.mutex.unlock();
    }

    ctx.info("oatuh keys refreshed");
}
