const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// S3-compatible object store (MinIO / R2 / Spaces / B2 / AWS S3).
///
/// Requests are signed with AWS Signature Version 4 over the existing `zul`
/// HTTP client. Object keys map directly to S3 keys under `bucket`:
/// `create(ctx, "avatars/1.png", ...)` -> `PUT /<bucket>/avatars/1.png`.
pub const FileStoreS3 = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    endpoint: []const u8,
    host: []const u8,
    region: []const u8,
    bucket: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    max_bytes: usize = 64 * 1024 * 1024,

    /// A signed (name, value) header participating in the SigV4 signature.
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Builds an S3 store from env config:
    ///   S3_ENDPOINT (optional; default https://s3.<region>.amazonaws.com)
    ///   S3_REGION   (default us-east-1)
    ///   S3_BUCKET   (required)
    ///   S3_ACCESS_KEY / S3_SECRET_KEY (required)
    pub fn open(allocator: std.mem.Allocator, container: *root.container) !*FileStoreS3 {
        const region = container.config.getOrDefault("S3_REGION", "us-east-1");
        const bucket = container.config.getOrDefault("S3_BUCKET", "");
        const access_key = container.config.getOrDefault("S3_ACCESS_KEY", "");
        const secret_key = container.config.getOrDefault("S3_SECRET_KEY", "");
        if (bucket.len == 0) return error.S3BucketRequired;
        if (access_key.len == 0 or secret_key.len == 0) return error.S3CredentialsRequired;

        const endpoint_cfg = container.config.getOrDefault("S3_ENDPOINT", "");
        const endpoint = if (endpoint_cfg.len > 0)
            try allocator.dupe(u8, endpoint_cfg)
        else
            try std.fmt.allocPrint(allocator, "https://s3.{s}.amazonaws.com", .{region});

        const self = try allocator.create(FileStoreS3);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .endpoint = endpoint,
            .host = try hostOf(allocator, endpoint),
            .region = try allocator.dupe(u8, region),
            .bucket = try allocator.dupe(u8, bucket),
            .access_key = try allocator.dupe(u8, access_key),
            .secret_key = try allocator.dupe(u8, secret_key),
        };
        return self;
    }

    fn objectUrl(self: *FileStoreS3, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const enc = try encodePath(allocator, key);
        defer allocator.free(enc);
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ self.endpoint, self.bucket, enc });
    }

    fn canonicalUri(self: *FileStoreS3, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const enc = try encodePath(allocator, key);
        defer allocator.free(enc);
        return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.bucket, enc });
    }

    fn authHeaders(
        self: *FileStoreS3,
        allocator: std.mem.Allocator,
        method: []const u8,
        uri: []const u8,
        payload_hash: []const u8,
    ) !struct { authorization: []const u8, amz_date: []const u8, content_sha256: []const u8 } {
        const amz_date = try amzDate(allocator);
        const signed = [_]Header{
            .{ .name = "host", .value = self.host },
            .{ .name = "x-amz-content-sha256", .value = payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };
        const authorization = try signAuthorization(
            allocator,
            method,
            uri,
            "",
            self.region,
            "s3",
            self.access_key,
            self.secret_key,
            payload_hash,
            amz_date,
            &signed,
        );
        return .{ .authorization = authorization, .amz_date = amz_date, .content_sha256 = try allocator.dupe(u8, payload_hash) };
    }

    pub fn create(self: *FileStoreS3, ctx: *root.Context, key: []const u8, data: []const u8) !void {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sha256Hex(data));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "PUT", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .PUT;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);
        req.body(data);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3PutFailed;
    }

    pub fn get(self: *FileStoreS3, ctx: *root.Context, key: []const u8) !?[]const u8 {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "GET", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

                var res = try req.getResponse(.{});
        if (res.status == 404) return null;
        if (res.status < 200 or res.status > 299) return error.S3GetFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        const slice = try ctx.allocator.dupe(u8, sb.string());
        sb.deinit();
        return slice;
    }

    pub fn delete(self: *FileStoreS3, ctx: *root.Context, key: []const u8) !void {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "DELETE", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .DELETE;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3DeleteFailed;
    }

    pub fn list(self: *FileStoreS3, ctx: *root.Context, prefix: []const u8) ![][]const u8 {
        const enc_prefix = try encodePath(ctx.allocator, prefix);
        defer ctx.allocator.free(enc_prefix);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}?list-type=2&prefix={s}", .{ self.endpoint, self.bucket, enc_prefix });
        defer ctx.allocator.free(url);
        const uri = try std.fmt.allocPrint(ctx.allocator, "/{s}/?list-type=2&prefix={s}", .{ self.bucket, enc_prefix });
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "GET", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var req = try self.client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

                var res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3ListFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        const body = try ctx.allocator.dupe(u8, sb.string());
        defer {
            sb.deinit();
            ctx.allocator.free(body);
        }

        // S3 list returns an XML <Contents> element per object; pull <Key> values.
        var out = std.array_list.Managed([]const u8).init(ctx.allocator);
        errdefer {
            for (out.items) |k| ctx.allocator.free(k);
            out.deinit();
        }
        var i: usize = 0;
        while (i < body.len) {
            const start = std.mem.indexOfPos(u8, body, i, "<Key>") orelse break;
            const after = start + "<Key>".len;
            const end = std.mem.indexOfPos(u8, body, after, "</Key>") orelse break;
            try out.append(try ctx.allocator.dupe(u8, body[after..end]));
            i = end + "</Key>".len;
        }
        return out.toOwnedSlice();
    }
};

/// Extracts the host (no scheme, no path) from an endpoint URL.
fn hostOf(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const rest = if (std.mem.indexOf(u8, endpoint, "://")) |idx|
        endpoint[idx + "://".len ..]
    else
        endpoint;
    const host = if (std.mem.indexOf(u8, rest, "/")) |s| rest[0..s] else rest;
    return try allocator.dupe(u8, host);
}

/// URI-encodes a key for use in a URL path, preserving `/` and the unreserved set.
fn encodePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (path) |c| {
        const safe = c == '/' or
            (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(c);
            continue;
        }
        var hex: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{X}", .{c}) catch unreachable;
        try out.append('%');
        try out.appendSlice(&hex);
    }
    return out.toOwnedSlice();
}

/// Current UTC time in AWS `YYYYMMDDTHHMMSSZ` form.
fn amzDate(allocator: std.mem.Allocator) ![]const u8 {
    const epoch_seconds: u64 = @intCast(@divTrunc(utils.nowReal().nanoseconds, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const year: u16 = @intCast(yd.year);
    const month: u8 = @intFromEnum(md.month);
    const day: u8 = md.day_index + 1;
    const hour = ds.getHoursIntoDay();
    const minute = ds.getMinutesIntoHour();
    const second = ds.getSecondsIntoMinute();
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year, month, day, hour, minute, second,
    });
}

// ---------------------------------------------------------------------------
// AWS Signature Version 4 (pure, unit-testable)
// ---------------------------------------------------------------------------

fn hmacSha256(key: []const u8, msg: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, msg, key);
    return out;
}

/// Lowercase big-endian hex encoding of a byte slice into a caller-owned buffer.
fn toHexLower(out: *[64]u8, bytes: []const u8) void {
    const set = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        out[i * 2] = set[bytes[i] >> 4];
        out[i * 2 + 1] = set[bytes[i] & 15];
    }
}

fn sha256Hex(data: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex: [64]u8 = undefined;
    toHexLower(&hex, &hash);
    return hex;
}

fn signingKey(allocator: std.mem.Allocator, secret: []const u8, date_stamp: []const u8, region: []const u8, service: []const u8) [32]u8 {
    const aws4_secret = std.fmt.allocPrint(allocator, "AWS4{s}", .{secret}) catch "AWS4";
    defer if (aws4_secret.len > 4) allocator.free(aws4_secret);
    var k = hmacSha256(aws4_secret, date_stamp);
    k = hmacSha256(&k, region);
    k = hmacSha256(&k, service);
    k = hmacSha256(&k, "aws4_request");
    return k;
}

fn canonicalHeaders(allocator: std.mem.Allocator, signed: []const FileStoreS3.Header) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    for (signed) |h| {
        try buf.appendSlice(h.name);
        try buf.append(':');
        try buf.appendSlice(h.value);
        try buf.append('\n');
    }
    return buf.toOwnedSlice();
}

fn signedHeadersString(allocator: std.mem.Allocator, signed: []const FileStoreS3.Header) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    for (signed, 0..) |h, i| {
        if (i > 0) try buf.append(';');
        try buf.appendSlice(h.name);
    }
    return buf.toOwnedSlice();
}

/// Computes the SigV4 `Authorization` header value. Pure: no I/O, no clock.
/// `signed` must be sorted ascending by header name and include `host` and
/// `x-amz-date` (S3 also requires `x-amz-content-sha256`).
pub fn signAuthorization(
    allocator: std.mem.Allocator,
    method: []const u8,
    uri: []const u8,
    query: []const u8,
    region: []const u8,
    service: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    payload_hash: []const u8,
    amz_date: []const u8,
    signed: []const FileStoreS3.Header,
) ![]const u8 {
    const ch = try canonicalHeaders(allocator, signed);
    defer allocator.free(ch);
    const sh = try signedHeadersString(allocator, signed);
    defer allocator.free(sh);

    const cr = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        method, uri, query, ch, sh, payload_hash,
    });
    defer allocator.free(cr);

    const cr_hash = sha256Hex(cr);
    const scope = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/aws4_request", .{ amz_date[0..8], region, service });
    defer allocator.free(scope);

    const sts = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, cr_hash });
    defer allocator.free(sts);

    const key = signingKey(allocator, secret_key, amz_date[0..8], region, service);
    const sig = hmacSha256(&key, sts);
    var sig_hex_buf: [64]u8 = undefined;
    toHexLower(&sig_hex_buf, &sig);
    const sig_hex = try allocator.dupe(u8, &sig_hex_buf);
    defer allocator.free(sig_hex);

    return std.fmt.allocPrint(allocator,
        \\AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}
    , .{ access_key, scope, sh, sig_hex });
}

test "FileStoreS3: hmac-sha256 (RFC 4231 case 2)" {
    const key = [_]u8{0x0b} ** 20;
    const data = "Hi There";
    const got = hmacSha256(&key, data);
    var got_hex: [64]u8 = undefined;
    toHexLower(&got_hex, &got);
    const exp = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    try std.testing.expectEqualStrings(exp, &got_hex);
}

test "FileStoreS3: sha256Hex(empty) matches the well-known empty digest" {
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
}

test "FileStoreS3: signAuthorization matches AWS get-vanilla test vector" {
    const signed = [_]FileStoreS3.Header{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "x-amz-date", .value = "20150830T123600Z" },
    };
    const auth = try signAuthorization(
        std.testing.allocator,
        "GET",
        "/",
        "",
        "us-east-1",
        "service",
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        &sha256Hex(""),
        "20150830T123600Z",
        &signed,
    );
    defer std.testing.allocator.free(auth);

    const expected = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31";
    try std.testing.expectEqualStrings(expected, auth);
}
