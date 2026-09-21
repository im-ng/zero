const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;

/// SQLite-backed KV store, layering on the existing `SQLite` datasource. Values
/// are stored in a `kv(k TEXT PRIMARY KEY, v BLOB, exp INTEGER)` table (created
/// lazily). `exp` is a monotonic nanosecond deadline (0 = no expiry).
pub const KVSQLite = struct {
    db: *root.SQLite,
    allocator: std.mem.Allocator,

    /// Frees the wrapper. `db` is borrowed from `container.SQL`, destroyed separately.
    pub fn deinit(self: *KVSQLite, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    fn ensure(self: *KVSQLite, ctx: *root.Context) !void {
        _ = try self.db.execWithContext(
            ctx,
            "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v BLOB, exp INTEGER)",
            .{},
        );
    }

    pub fn get(self: *KVSQLite, ctx: *root.Context, key: []const u8) !?[]const u8 {
        try self.ensure(ctx);
        const row = try self.db.queryRow(ctx, Row, "SELECT v, exp FROM kv WHERE k = ?", .{key});
        if (row) |r| {
            if (r.exp == 0 or utils.nowMonotonic().nanoseconds < r.exp) {
                return try ctx.allocator.dupe(u8, r.v);
            }
        }
        return null;
    }

    pub fn set(self: *KVSQLite, ctx: *root.Context, key: []const u8, value: []const u8) !void {
        try self.ensure(ctx);
        _ = try self.db.execWithContext(
            ctx,
            "INSERT INTO kv(k, v, exp) VALUES(?, ?, 0) ON CONFLICT(k) DO UPDATE SET v = excluded.v, exp = 0",
            .{ key, value },
        );
    }

    pub fn delete(self: *KVSQLite, ctx: *root.Context, key: []const u8) !void {
        try self.ensure(ctx);
        _ = try self.db.execWithContext(ctx, "DELETE FROM kv WHERE k = ?", .{key});
    }

    pub fn exists(self: *KVSQLite, ctx: *root.Context, key: []const u8) !bool {
        const v = try self.get(ctx, key);
        const found = v != null;
        if (v) |s| ctx.allocator.free(s);
        return found;
    }

    pub fn expire(self: *KVSQLite, ctx: *root.Context, key: []const u8, ms: i64) !void {
        try self.ensure(ctx);
        _ = try self.db.execWithContext(
            ctx,
            "UPDATE kv SET exp = ? WHERE k = ?",
            .{ utils.nowMonotonic().nanoseconds + @as(i128, ms) * 1_000_000, key },
        );
    }
};

const Row = struct {
    v: []const u8,
    exp: i64,
};
