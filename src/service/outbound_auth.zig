const std = @import("std");

pub const OutboundAuthMode = enum {
    none,
    basic,
    apiKey,
    oauth,
};

pub const BasicConfig = struct {
    username: []const u8,
    password: []const u8,
};

pub const ApiKeyConfig = struct {
    key: []const u8,
};

pub const OAuthConfig = struct {
    tokenUrl: []const u8,
    clientId: []const u8,
    clientSecret: []const u8,
    scope: ?[]const u8 = null,
    audience: ?[]const u8 = null,
};

pub const OutboundAuth = struct {
    mode: OutboundAuthMode,
    basic: ?BasicConfig = null,
    apiKey: ?ApiKeyConfig = null,
    oauth: ?OAuthConfig = null,

    /// Build the static auth header (name + value) for a request. OAuth is excluded
    /// here because its token must be fetched at request time; the client handles it
    /// via its token cache. Returns `null` when no header should be attached.
    pub fn buildHeader(self: OutboundAuth, allocator: std.mem.Allocator) !?struct { name: []const u8, value: []const u8 } {
        return switch (self.mode) {
            .none => null,
            .basic => blk: {
                const cfg = self.basic orelse return null;
                const raw = try std.fmt.allocPrint(
                    allocator,
                    "{s}:{s}",
                    .{ cfg.username, cfg.password },
                );
                defer allocator.free(raw);

                const b64_len = std.base64.standard.Encoder.calcSize(raw.len);
                const b64 = try allocator.alloc(u8, b64_len);
                _ = std.base64.standard.Encoder.encode(b64, raw);

                const value = try std.fmt.allocPrint(allocator, "Basic {s}", .{b64});
                allocator.free(b64);

                break :blk .{ .name = "authorization", .value = value };
            },
            .apiKey => blk: {
                const cfg = self.apiKey orelse return null;

                break :blk .{
                    .name = "x-api-key",
                    .value = try allocator.dupe(u8, cfg.key),
                };
            },
            .oauth => null,
        };
    }
};

test "buildHeader basic encodes credentials" {
    const auth = OutboundAuth{ .mode = .basic, .basic = .{ .username = "user", .password = "pass" } };
    const h = try auth.buildHeader(std.testing.allocator);
    try std.testing.expectEqualStrings("authorization", h.?.name);
    try std.testing.expectEqualStrings("Basic dXNlcjpwYXNz", h.?.value);
    std.testing.allocator.free(h.?.value);
}

test "buildHeader apiKey sets x-api-key" {
    const auth = OutboundAuth{ .mode = .apiKey, .apiKey = .{ .key = "secret-key" } };
    const h = try auth.buildHeader(std.testing.allocator);
    try std.testing.expectEqualStrings("x-api-key", h.?.name);
    try std.testing.expectEqualStrings("secret-key", h.?.value);
    std.testing.allocator.free(h.?.value);
}

test "buildHeader none returns null" {
    const auth = OutboundAuth{ .mode = .none };
    try std.testing.expect(try auth.buildHeader(std.testing.allocator) == null);
}
