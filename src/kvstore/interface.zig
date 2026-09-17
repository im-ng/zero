const std = @import("std");
const root = @import("../zero.zig");
const service = root.circuit_breaker;

/// Backend implementations available through the `KVStore` interface.
pub const Backend = enum {
    redis,
    nats_kv,
    memory,
    sqlite,
};

/// Options used when registering a store via `App.addKVStore`.
pub const Options = struct {
    /// Bucket name for `nats_kv`. Ignored by other backends.
    bucket: []const u8 = "",
};

/// Unified, type-erased KV store handle. Mirrors `root.Datasource` so a caller
/// can use `get`/`set`/`delete`/`exists`/`expire` without knowing the backend.
///
/// Returned slices from `get` are allocated with `ctx.allocator` and owned by
/// the caller (free with `ctx.allocator.free`).
pub const KVStore = struct {
    ptr: *anyopaque,
    backend: Backend,
    /// Optional circuit breaker guarding all backend calls. When `null`, calls
    /// pass straight through. Enable via `CACHE_CIRCUIT_BREAKER_ENABLE`.
    breaker: ?service.CircuitBreaker = null,

    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker) KVStore {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
        };
    }

    pub fn get(self: *KVStore, ctx: *root.Context, key: []const u8) !?[]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .redis => @as(*redis.KVRedis, @ptrCast(@alignCast(self.ptr))).get(ctx, key),
            .nats_kv => @as(*natskv.KVNats, @ptrCast(@alignCast(self.ptr))).get(ctx, key),
            .memory => @as(*memory.KVMemory, @ptrCast(@alignCast(self.ptr))).get(ctx, key),
            .sqlite => @as(*sqlite.KVSQLite, @ptrCast(@alignCast(self.ptr))).get(ctx, key),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    pub fn set(self: *KVStore, ctx: *root.Context, key: []const u8, value: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        (switch (self.backend) {
            .redis => @as(*redis.KVRedis, @ptrCast(@alignCast(self.ptr))).set(ctx, key, value),
            .nats_kv => @as(*natskv.KVNats, @ptrCast(@alignCast(self.ptr))).set(ctx, key, value),
            .memory => @as(*memory.KVMemory, @ptrCast(@alignCast(self.ptr))).set(ctx, key, value),
            .sqlite => @as(*sqlite.KVSQLite, @ptrCast(@alignCast(self.ptr))).set(ctx, key, value),
        }) catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
    }

    pub fn delete(self: *KVStore, ctx: *root.Context, key: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        (switch (self.backend) {
            .redis => @as(*redis.KVRedis, @ptrCast(@alignCast(self.ptr))).delete(ctx, key),
            .nats_kv => @as(*natskv.KVNats, @ptrCast(@alignCast(self.ptr))).delete(ctx, key),
            .memory => @as(*memory.KVMemory, @ptrCast(@alignCast(self.ptr))).delete(ctx, key),
            .sqlite => @as(*sqlite.KVSQLite, @ptrCast(@alignCast(self.ptr))).delete(ctx, key),
        }) catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
    }

    pub fn exists(self: *KVStore, ctx: *root.Context, key: []const u8) !bool {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .redis => @as(*redis.KVRedis, @ptrCast(@alignCast(self.ptr))).exists(ctx, key),
            .nats_kv => @as(*natskv.KVNats, @ptrCast(@alignCast(self.ptr))).exists(ctx, key),
            .memory => @as(*memory.KVMemory, @ptrCast(@alignCast(self.ptr))).exists(ctx, key),
            .sqlite => @as(*sqlite.KVSQLite, @ptrCast(@alignCast(self.ptr))).exists(ctx, key),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    pub fn expire(self: *KVStore, ctx: *root.Context, key: []const u8, ms: i64) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        (switch (self.backend) {
            .redis => @as(*redis.KVRedis, @ptrCast(@alignCast(self.ptr))).expire(ctx, key, ms),
            .nats_kv => @as(*natskv.KVNats, @ptrCast(@alignCast(self.ptr))).expire(ctx, key, ms),
            .memory => @as(*memory.KVMemory, @ptrCast(@alignCast(self.ptr))).expire(ctx, key, ms),
            .sqlite => @as(*sqlite.KVSQLite, @ptrCast(@alignCast(self.ptr))).expire(ctx, key, ms),
        }) catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
    }
};

/// Construct a backend instance from the container's configured connections and
/// wrap it in a type-erased `KVStore`. The returned handle is owned by the
/// caller (typically `container.kvStores`).
pub fn build(container: *root.container, backend: Backend, opts: Options) !*KVStore {
    const store = try container.allocator.create(KVStore);
    errdefer container.allocator.destroy(store);

    // Optional circuit breaker guarding cache operations (fails fast when the
    // backend is unhealthy). Opt-in via CACHE_CIRCUIT_BREAKER_ENABLE.
    const breaker: ?service.CircuitBreaker = if (container.config.getAsBool("CACHE_CIRCUIT_BREAKER_ENABLE"))
        service.CircuitBreaker.init(.{})
    else
        null;

    switch (backend) {
        .redis => {
            if (container.redis == null) return error.RedisNotConfigured;
            const b = try container.allocator.create(redis.KVRedis);
            b.* = .{ .client = container.redis.?, .mutex = .{} };
            store.* = KVStore.init(b, .redis, breaker);
        },
        .memory => {
            const b = try memory.KVMemory.create(container.allocator);
            store.* = KVStore.init(b, .memory, breaker);
        },
        .nats_kv => {
            if (container.Nats == null or container.Nats.?.js == null) {
                return error.NatsJetStreamNotConfigured;
            }
            const kv = try container.Nats.?.js.?.createOrUpdateKeyValue(.{ .bucket = opts.bucket });
            const b = try container.allocator.create(natskv.KVNats);
            b.* = .{ .kv = kv };
            store.* = KVStore.init(b, .nats_kv, breaker);
        },
        .sqlite => {
            if (container.SQLite == null) return error.SQLiteNotConfigured;
            const b = try container.allocator.create(sqlite.KVSQLite);
            b.* = .{ .db = container.SQLite.?, .allocator = container.allocator };
            store.* = KVStore.init(b, .sqlite, breaker);
        },
    }
    return store;
}

pub const redis = @import("redis.zig");
pub const natskv = @import("natskv.zig");
pub const memory = @import("memory.zig");
pub const sqlite = @import("sqlite.zig");
