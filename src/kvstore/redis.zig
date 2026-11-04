const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;

/// Redis-backed KV store, wrapping `rediz.Client` (okredis).
///
/// The underlying `rediz.Client` is a single shared connection; without
/// serialization, concurrent requests would interleave their RESP frames on the
/// socket and corrupt the stream. A mutex makes every command a full
/// request/response round-trip, so the shared connection is safe to use from the
/// worker pool. (A connection pool is the higher-throughput follow-up)
pub const KVRedis = struct {
    // Shared Redis connection + lock. All Redis consumers (KV, rate limiter,
    // health probe) serialize on `rdz.mu` around the single socket, so concurrent
    // requests can't interleave RESP frames The `client` lives
    // on `rdz` and outlives this wrapper.
    rdz: *root.rdz,

    pub fn get(self: *KVRedis, ctx: *root.Context, key: []const u8) !?[]const u8 {
        self.rdz.mu.lock(utils.io) catch {};
        defer self.rdz.mu.unlock(utils.io);
        return try self.rdz.client.sendAlloc(?[]const u8, ctx.allocator, .{ "GET", key });
    }

    pub fn set(self: *KVRedis, _: *root.Context, key: []const u8, value: []const u8) !void {
        self.rdz.mu.lock(utils.io) catch {};
        defer self.rdz.mu.unlock(utils.io);
        try self.rdz.client.send(void, .{ "SET", key, value });
    }

    pub fn delete(self: *KVRedis, _: *root.Context, key: []const u8) !void {
        self.rdz.mu.lock(utils.io) catch {};
        defer self.rdz.mu.unlock(utils.io);
        try self.rdz.client.send(void, .{ "DEL", key });
    }

    pub fn exists(self: *KVRedis, _: *root.Context, key: []const u8) !bool {
        self.rdz.mu.lock(utils.io) catch {};
        defer self.rdz.mu.unlock(utils.io);
        const n = try self.rdz.client.send(i64, .{ "EXISTS", key });
        return n > 0;
    }

    pub fn expire(self: *KVRedis, _: *root.Context, key: []const u8, ms: i64) !void {
        self.rdz.mu.lock(utils.io) catch {};
        defer self.rdz.mu.unlock(utils.io);
        try self.rdz.client.send(void, .{ "PEXPIRE", key, ms });
    }

    /// Frees the wrapper. `rdz` (and its client) are owned by the container and
    /// destroyed separately during teardown.
    pub fn deinit(self: *KVRedis, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};
