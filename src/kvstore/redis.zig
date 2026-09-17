const std = @import("std");
const root = @import("../zero.zig");
const rediz = root.rediz;
const utils = root.utils;

/// Zig 0.16 removed `std.Thread.Mutex`; this is a minimal blocking mutex built
/// on the spinlock `std.atomic.Mutex` so the `lock()`/`unlock()` call-sites
/// below stay unchanged.
const BlockingMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(m: *@This()) void {
        while (!m.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(m: *@This()) void {
        m.inner.unlock();
    }
};

/// Redis-backed KV store, wrapping `rediz.Client` (okredis).
///
/// The underlying `rediz.Client` is a single shared connection; without
/// serialization, concurrent requests would interleave their RESP frames on the
/// socket and corrupt the stream. A mutex makes every command a full
/// request/response round-trip, so the shared connection is safe to use from the
/// worker pool. (A connection pool is the higher-throughput follow-up — see
/// ZIG_LEARNINGS.md.)
pub const KVRedis = struct {
    client: rediz.Client,
    mutex: BlockingMutex = .{},

    pub fn get(self: *KVRedis, ctx: *root.Context, key: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try self.client.sendAlloc(?[]const u8, ctx.allocator, .{ "GET", key });
    }

    pub fn set(self: *KVRedis, _: *root.Context, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.send(void, .{ "SET", key, value });
    }

    pub fn delete(self: *KVRedis, _: *root.Context, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.send(void, .{ "DEL", key });
    }

    pub fn exists(self: *KVRedis, _: *root.Context, key: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = try self.client.send(i64, .{ "EXISTS", key });
        return n > 0;
    }

    pub fn expire(self: *KVRedis, _: *root.Context, key: []const u8, ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.send(void, .{ "PEXPIRE", key, ms });
    }
};
