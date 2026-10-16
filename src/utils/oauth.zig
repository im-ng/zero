const std = @import("std");
const root = @import("../zero.zig");

/// OAuth2 client-credentials token response (subset we depend on).
pub const TokenResp = struct {
    access_token: []const u8,
    expires_in: u64 = 3600,
};

/// Fetches an OAuth2 access token via the client-credentials grant and returns
/// a caller-owned token (free with `allocator.free`). Used by both the GCS
/// file store and GCP Pub/Sub so the token-fetch logic lives in one place.
pub fn fetchToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: []const u8,
) ![]const u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    try body.appendSlice("grant_type=client_credentials");
    try body.appendSlice("&client_id=");
    try body.appendSlice(client_id);
    try body.appendSlice("&client_secret=");
    try body.appendSlice(client_secret);
    try body.appendSlice("&scope=");
    try body.appendSlice(scope);

    var client = root.zul.http.Client.init(io, allocator);
    defer client.deinit();
    var req = try client.allocRequest(allocator, token_url);
    defer req.deinit();
    req.method = .POST;
    try req.header("content-type", "application/x-www-form-urlencoded");
    req.body(body.items);

    var res = try req.getResponse(.{});
    if (res.status < 200 or res.status > 299) return error.GcpTokenFetchFailed;

    var sb = try res.allocBody(allocator, .{ .max_size = 4096 });
    defer sb.deinit();
    const parsed = std.json.parseFromSlice(TokenResp, allocator, sb.string(), .{}) catch {
        return error.GcpTokenFetchFailed;
    };
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.access_token);
}
