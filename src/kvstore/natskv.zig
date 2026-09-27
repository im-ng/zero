const std = @import("std");
const root = @import("../zero.zig");
const natslib = root.natslib;
const utils = root.utils;

/// NATS JetStream KV-backed store. Requires a JetStream-enabled NATS connection
/// (`container.Nats` with `js` initialized); the bucket is created on registration.
pub const KVNats = struct {
    kv: natslib.jetstream.KeyValue,

    /// Frees the wrapper. `kv` is borrowed from `container.Nats`, destroyed separately.
    pub fn deinit(self: *KVNats, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn get(self: *KVNats, ctx: *root.Context, key: []const u8) !?[]const u8 {
        const entry = try self.kv.get(key);
        if (entry) |e| {
            const value = try ctx.allocator.dupe(u8, e.value);
            var owned = e;
            owned.deinit();
            return value;
        }
        return null;
    }

    pub fn set(self: *KVNats, _: *root.Context, key: []const u8, value: []const u8) !void {
        _ = try self.kv.put(key, value);
    }

    pub fn delete(self: *KVNats, _: *root.Context, key: []const u8) !void {
        _ = try self.kv.delete(key);
    }

    pub fn exists(self: *KVNats, _: *root.Context, key: []const u8) !bool {
        const entry = try self.kv.get(key);
        if (entry) |e| {
            var owned = e;
            owned.deinit();
            return true;
        }
        return false;
    }

    pub fn expire(_: *KVNats, _: *root.Context, _: []const u8, _: i64) !void {
        // JetStream KV has bucket-level TTL only; per-key expiry is not supported
        // by the protocol, so we surface it as an error rather than silently no-op.
        return error.Unsupported;
    }
};
