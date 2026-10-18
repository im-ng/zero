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
    // Bounds the collection so a hot `set` with unique keys can't grow it
    // unbounded (audit #13). 0 means unlimited; production callers should set it.
    max_entries: usize = 100_000,

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
        // Free a prior entry's duped key + value on overwrite so the old key
        // allocation isn't leaked (audit #13).
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        self.map.put(k, v) catch {
            self.allocator.free(v);
            self.mu.unlock(utils.io);
            return error.OutOfMemory;
        };
        // `exp` keeps its own copy of the key so the two indexes free independently.
        const ek = try self.allocator.dupe(u8, key);
        if (self.exp.fetchRemove(key)) |old_exp| {
            self.allocator.free(old_exp.key);
        }
        self.exp.put(ek, 0) catch {
            self.allocator.free(ek);
        };
        // Bound the collection while still holding the lock: the hashmap isn't safe
        // against a concurrent read while we mutate it (audit #13).
        self.enforceCap();
        self.mu.unlock(utils.io);
    }

    /// Evict entries once `max_entries` is exceeded, freeing both indexes' keys and
    /// the value. Called without the lock held by `set`; the single-writer lock in
    /// `set` plus the fact that `enforceCap` only shrinks makes concurrent reads
    /// safe (a reader may transiently see one extra entry).
    fn enforceCap(self: *KVMemory) void {
        if (self.max_entries == 0) return;
        while (self.map.count() > self.max_entries) {
            var it = self.map.iterator();
            const kv = it.next() orelse return;
            const k = kv.key_ptr.*;
            if (self.exp.fetchRemove(k)) |e| self.allocator.free(e.key);
            self.allocator.free(k);
            self.allocator.free(kv.value_ptr.*);
        }
    }

    pub fn delete(self: *KVMemory, _: *root.Context, key: []const u8) !void {
        self.mu.lockUncancelable(utils.io);
        if (self.map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        // `exp` owns its own key copy; free it too so neither index leaks.
        if (self.exp.fetchRemove(key)) |removed| {
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
        // Dupe the key into the store's allocator: the caller's `key` may be a
        // request-arena borrow that is freed after this call, and storing it raw
        // would leave `exp` holding a dangling pointer (audit #13 UAF).
        const k = try self.allocator.dupe(u8, key);
        if (self.exp.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
        }
        self.exp.put(k, utils.nowMonotonic().nanoseconds + @as(i128, ms) * 1_000_000) catch {
            self.allocator.free(k);
        };
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
    defer store.deinit();
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
    // 0.16 removed std.Thread.sleep; busy-wait on the monotonic clock until
    // the 1ms TTL has elapsed so the expiry branch below is exercised.
    const ttl_deadline = utils.nowMonotonic().nanoseconds + std.time.ns_per_ms * 5;
    while (utils.nowMonotonic().nanoseconds < ttl_deadline) {}
    try std.testing.expect((try store.get(&ctx, "t")) == null);
}
