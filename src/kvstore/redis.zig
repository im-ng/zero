const std = @import("std");
const root = @import("../zero.zig");
const rediz = root.rediz;
const utils = root.utils;

/// Redis-backed KV store, wrapping `rediz.Client` (okredis).
pub const KVRedis = struct {
    client: rediz.Client,

    pub fn get(self: *KVRedis, ctx: *root.Context, key: []const u8) !?[]const u8 {
        return try self.client.sendAlloc(?[]const u8, ctx.allocator, .{ "GET", key });
    }

    pub fn set(self: *KVRedis, _: *root.Context, key: []const u8, value: []const u8) !void {
        try self.client.send(void, .{ "SET", key, value });
    }

    pub fn delete(self: *KVRedis, _: *root.Context, key: []const u8) !void {
        try self.client.send(void, .{ "DEL", key });
    }

    pub fn exists(self: *KVRedis, _: *root.Context, key: []const u8) !bool {
        const n = try self.client.send(i64, .{ "EXISTS", key });
        return n > 0;
    }

    pub fn expire(self: *KVRedis, _: *root.Context, key: []const u8, ms: i64) !void {
        try self.client.send(void, .{ "PEXPIRE", key, ms });
    }
};
