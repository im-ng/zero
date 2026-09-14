const std = @import("std");
const root = @import("../zero.zig");
const service = root.circuit_breaker;

/// NoSQL backends (document / wide-column). Resolved at runtime from config so the
/// same type-erased `NoSQL` handle works for any configured backend. Add new
/// backends (MongoDB, Couchbase, …) here and a case in the `switch`.
pub const Backend = enum {
    cassandra,
    /// Test-only backend backed by `MockBackend`. Lets the `NoSQL` dispatch be
    /// exercised without a running database.
    mock,
};

/// Connection options for a `NoSQL` backend.
pub const Options = struct {
    /// Comma-separated contact points, e.g. "127.0.0.1:9042".
    contact_points: []const u8,
    keyspace: []const u8,
    /// Optional auth.
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// Unified, type-erased NoSQL interface.
///
/// Usage (mirrors `ctx.SQL`):
///   try ctx.NoSQL.put(ctx, "users", "alice", "{...}");
///   const doc = try ctx.NoSQL.get(ctx, "users", "alice");
pub const NoSQL = struct {
    ptr: *anyopaque,
    backend: Backend,
    breaker: ?service.CircuitBreaker = null,

    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker) NoSQL {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
        };
    }

    pub fn build(container: *root.container, backend: Backend, opts: Options) !*NoSQL {
        const impl: *anyopaque = switch (backend) {
            .cassandra => blk: {
                const c = try root.Cassandra.create(container.allocator, .{
                    .contact_points = opts.contact_points,
                    .keyspace = opts.keyspace,
                    .user = opts.user,
                    .password = opts.password,
                });
                break :blk @as(*anyopaque, c);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{ .last_value = "" };
                break :blk @as(*anyopaque, mb);
            },
        };
        const handle = try container.allocator.create(NoSQL);
        handle.* = NoSQL.init(impl, backend, null);
        return handle;
    }

    /// Fetch a document/row by key. Returns the raw value (owned by `ctx.allocator`)
    /// or `null` if absent. Caller frees.
    pub fn get(self: *NoSQL, ctx: *root.Context, collection: []const u8, key: []const u8) !?[]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .cassandra => @as(*root.Cassandra, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, key),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, key),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Upsert a document/row by key. `value` is the raw payload (JSON for
    /// document backends, a CQL literal for wide-column).
    pub fn put(self: *NoSQL, ctx: *root.Context, collection: []const u8, key: []const u8, value: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .cassandra => @as(*root.Cassandra, @ptrCast(@alignCast(self.ptr))).put(ctx, collection, key, value),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).put(ctx, collection, key, value),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Delete a document/row by key.
    pub fn delete(self: *NoSQL, ctx: *root.Context, collection: []const u8, key: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .cassandra => @as(*root.Cassandra, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, key),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, key),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Run a backend-native query (CQL / MQL) and return the raw response body,
    /// owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *NoSQL, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .cassandra => @as(*root.Cassandra, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }
};

/// Native-free backend used by tests to verify `NoSQL` dispatch.
pub const MockBackend = struct {
    gets: u32 = 0,
    puts: u32 = 0,
    deletes: u32 = 0,
    queries: u32 = 0,
    last_value: []const u8,

    pub fn get(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) !?[]const u8 {
        self.gets += 1;
        return null;
    }

    pub fn put(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8, value: []const u8) !void {
        self.puts += 1;
        self.last_value = value;
    }

    pub fn delete(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) !void {
        self.deletes += 1;
    }

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }
};


// ===================== Tests =====================


test "NoSQL dispatches through the type-erased handle" {
    var mock: MockBackend = .{ .last_value = "" };
    var n = NoSQL.init(&mock, .mock, null);
    var ctx_storage: root.Context = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ctx_storage.allocator = arena.allocator();

    try n.put(&ctx_storage, "users", "alice", "{\"age\":30}");
    try std.testing.expectEqual(@as(u32, 1), mock.puts);
    try std.testing.expectEqualStrings("{\"age\":30}", mock.last_value);

    _ = try n.get(&ctx_storage, "users", "alice");
    try std.testing.expectEqual(@as(u32, 1), mock.gets);

    try n.delete(&ctx_storage, "users", "alice");
    try std.testing.expectEqual(@as(u32, 1), mock.deletes);

    _ = try n.query(&ctx_storage, "users", "SELECT * FROM users");
    try std.testing.expectEqual(@as(u32, 1), mock.queries);
}
