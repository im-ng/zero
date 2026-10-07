const std = @import("std");
const root = @import("../zero.zig");

/// AWS Signature Version 4 (pure, unit-testable, header + query variants).
///
/// Shared by every AWS-backed client (S3 / Supabase Storage, SQS) so the
/// signing core lives in exactly one place. Mirrors the algorithm in
/// `filestore/s3.zig` (which now delegates here) and the AWS "GET vanilla"
/// test vector.
/// Lowercase big-endian hex encoding of a byte slice into a caller-owned buffer.
pub fn toHexLower(out: *[64]u8, bytes: []const u8) void {
    const set = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        out[i * 2] = set[bytes[i] >> 4];
        out[i * 2 + 1] = set[bytes[i] & 15];
    }
}

pub fn hmacSha256(key: []const u8, msg: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, msg, key);
    return out;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex: [64]u8 = undefined;
    toHexLower(&hex, &hash);
    return hex;
}

pub fn signingKey(allocator: std.mem.Allocator, secret: []const u8, date_stamp: []const u8, region: []const u8, service: []const u8) [32]u8 {
    const aws4_secret = std.fmt.allocPrint(allocator, "AWS4{s}", .{secret}) catch "AWS4";
    defer if (aws4_secret.len > 4) allocator.free(aws4_secret);
    var k = hmacSha256(aws4_secret, date_stamp);
    k = hmacSha256(&k, region);
    k = hmacSha256(&k, service);
    k = hmacSha256(&k, "aws4_request");
    return k;
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub fn canonicalHeaders(allocator: std.mem.Allocator, signed: []const Header) ![]const u8 {
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

pub fn signedHeadersString(allocator: std.mem.Allocator, signed: []const Header) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    for (signed, 0..) |h, i| {
        if (i > 0) {
            try buf.append(';');
        }
        try buf.appendSlice(h.name);
    }
    return buf.toOwnedSlice();
}

/// Computes the SigV4 `Authorization` header value. Pure: no I/O, no clock.
/// `signed` must be sorted ascending by header name and include every header
/// that participates in the signature (e.g. `host`, `x-amz-date`,
/// `x-amz-content-sha256`).
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
    signed: []const Header,
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

/// Current UTC time in AWS `YYYYMMDDTHHMMSSZ` form.
pub fn amzDate(allocator: std.mem.Allocator) ![]const u8 {
    const epoch_seconds: u64 = @intCast(@divFloor(root.utils.nowReal().nanoseconds, 1_000_000_000));
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

/// Extracts the host (no scheme, no path) from an endpoint URL.
pub fn hostOf(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const rest = if (std.mem.indexOf(u8, endpoint, "://")) |idx|
        endpoint[idx + "://".len ..]
    else
        endpoint;
    const host = if (std.mem.indexOf(u8, rest, "/")) |s| rest[0..s] else rest;
    return try allocator.dupe(u8, host);
}

/// URI-encodes a key for use in a URL path, preserving `/` and the unreserved set.
pub fn encodePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
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

// ===================== Tests =====================

test "sigv4: hmac-sha256 (RFC 4231 case 2)" {
    const key = [_]u8{0x0b} ** 20;
    const data = "Hi There";
    const got = hmacSha256(&key, data);
    var got_hex: [64]u8 = undefined;
    toHexLower(&got_hex, &got);
    const exp = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    try std.testing.expectEqualStrings(exp, &got_hex);
}

test "sigv4: sha256Hex(empty) matches the well-known empty digest" {
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
}

test "sigv4: signAuthorization matches AWS S3 GET Object vector" {
    // Authoritative, fully-worked example from the AWS SigV4 docs
    // ("Example: GET Object"): canonical-request hash
    // 7344ae5b..., signature f0e8bdb8....
    const empty = sha256Hex("");
    const signed = [_]Header{
        .{ .name = "host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "range", .value = "bytes=0-9" },
        .{ .name = "x-amz-content-sha256", .value = &empty },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
    };
    const auth = try signAuthorization(
        std.testing.allocator,
        "GET",
        "/test.txt",
        "",
        "us-east-1",
        "s3",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        &empty,
        "20130524T000000Z",
        &signed,
    );
    defer std.testing.allocator.free(auth);

    const expected = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41";
    try std.testing.expectEqualStrings(expected, auth);
}
