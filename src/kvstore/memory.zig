const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;

/// In-process KV store. Zero external dependencies; safe for `zig test` (no I/O).
/// Keys and values are copied into the store's allocator. `expire` uses a
/// monotonic deadline (milliseconds).
pub const KVMemory = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),
    exp: std.StringHashMap(i128),
    mu: std.Io.Mutex,

    pub fn create(allocator: std.mem.Allocator) !*KVMemory {
        const m = try allocator.create(KVMemory);
        m.* = .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
            .exp = std.StringHashMap(i128).init(allocator),
            .mu = .init,
        };
        return m;
    }

    pub fn get(self: *KVMemory, ctx: *root.Context, key: []const u8) !?[]const u8 {
        self.mu.lockUncancelable(utils.io);
        const v = self.map.get(key);
        const e = self.exp.get(key) orelse 0;
        const expired = e != 0 and utils.nowMonotonic().nanoseconds >= e;
        if (v == null or expired) {
            // Evict eagerly so expired keys (and the values they hold) cannot
            // accumulate forever — a cache that never reclaims is a leak.
            if (self.map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            }
            if (self.exp.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
            self.mu.unlock(utils.io);
            return null;
        }
        const duped = try ctx.allocator.dupe(u8, v.?);
        self.mu.unlock(utils.io);
        return duped;
    }

    pub fn set(self: *KVMemory, _: *root.Context, key: []const u8, value: []const u8) !void {
        self.mu.lockUncancelable(utils.io);
        const k = try self.allocator.dupe(u8, key);
        if (self.map.get(k)) |old| self.allocator.free(old);
        self.map.put(k, try self.allocator.dupe(u8, value)) catch {
            self.mu.unlock(utils.io);
            return error.OutOfMemory;
        };
        _ = self.exp.put(k, 0) catch 0;
        self.mu.unlock(utils.io);
    }

    pub fn delete(self: *KVMemory, _: *root.Context, key: []const u8) !void {
        self.mu.lockUncancelable(utils.io);
        if (self.map.get(key)) |old| {
            self.allocator.free(old);
        }
        if (self.exp.get(key)) |_| {
            _ = self.exp.fetchRemove(key);
        }
        if (self.map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
        }
        self.mu.unlock(utils.io);
    }

    pub fn exists(self: *KVMemory, _: *root.Context, key: []const u8) !bool {
        self.mu.lockUncancelable(utils.io);
        const v = self.map.get(key);
        const e = self.exp.get(key) orelse 0;
        const expired = e != 0 and utils.nowMonotonic().nanoseconds >= e;
        if (v == null or expired) {
            // Mirror `get`: reclaim expired entries on read so they cannot leak.
            if (self.map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            }
            if (self.exp.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
            self.mu.unlock(utils.io);
            return false;
        }
        self.mu.unlock(utils.io);
        return true;
    }

    pub fn expire(self: *KVMemory, _: *root.Context, key: []const u8, ms: i64) !void {
        self.mu.lockUncancelable(utils.io);
        _ = self.exp.put(key, utils.nowMonotonic().nanoseconds + @as(i128, ms) * 1_000_000) catch 0;
        self.mu.unlock(utils.io);
    }

    /// Frees every stored value, both indexes, and the wrapper struct.
    pub fn deinit(self: *KVMemory) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.map.deinit();
        self.exp.deinit();
        self.allocator.destroy(self);
    }
};

// ===================== Tests =====================

test "KVMemory get/set/delete/exists/expire" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const store = try KVMemory.create(allocator);
    var ctx: root.Context = .{ .allocator = allocator };

    try store.set(&ctx, "a", "1");
    const v = (try store.get(&ctx, "a")).?;
    defer allocator.free(v);
    try std.testing.expectEqualSlices(u8, "1", v);

    try std.testing.expect(try store.exists(&ctx, "a"));
    try std.testing.expect(!try store.exists(&ctx, "missing"));

    try store.delete(&ctx, "a");
    try std.testing.expect(!try store.exists(&ctx, "a"));
    try std.testing.expect((try store.get(&ctx, "a")) == null);

    // ttl
    try store.set(&ctx, "t", "x");
    try store.expire(&ctx, "t", 1);
    std.Thread.sleep(std.time.ns_per_ms * 5);
    try std.testing.expect((try store.get(&ctx, "t")) == null);
}
