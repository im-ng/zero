const std = @import("std");
const root = @import("../zero.zig");
const service = root.circuit_breaker;
const utils = root.utils;

/// NoSQL backends (document / wide-column). Resolved at runtime from config so the
/// same type-erased `NoSQL` handle works for any configured backend. Add new
/// backends (MongoDB, Couchbase, …) here and a case in the `switch`.
pub const Backend = enum {
    cassandra,
    /// Document backend over N1QL/HTTP (no `libcouchbase` C link). Backed by
    /// `src/datasource/couchbase.zig` (HTTP via `zul`).
    couchbase,
    /// Document backend over the pure-Zig OP_MSG wire protocol (no `mongo-c-driver`
    /// C link). Backed by `src/datasource/mongodb.zig`.
    mongodb,
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
/// Usage (mirrors `ctx.SQL` — the caller supplies the statement):
///   try ctx.NoSQL.put(ctx, "INSERT INTO users (id, data) VALUES ('alice', '{...}')");
///   const doc = try ctx.NoSQL.get(ctx, "SELECT data FROM users WHERE id = 'alice'");
pub const NoSQL = struct {
    ptr: *anyopaque,
    backend: Backend,
    breaker: ?service.CircuitBreaker = null,
    metricz: ?*root.metricz = null,

    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker, metricz: ?*root.metricz) NoSQL {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
            .metricz = metricz,
        };
    }

    fn backendName(b: Backend) []const u8 {
        return switch (b) {
            .cassandra => "cassandra",
            .couchbase => "couchbase",
            .mongodb => "mongodb",
            .mock => "mock",
        };
    }

    fn dsError(self: *NoSQL, op: []const u8) void {
        var status: u16 = 0;
        if (self.lastError()) |d| status = d.status;
        if (self.metricz) |mz| {
            mz.datasourceError(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = status }) catch {};
        }
    }

    fn dsOk(self: *NoSQL, op: []const u8, start: std.Io.Timestamp) void {
        if (self.metricz) |mz| {
            mz.datasourceResponse(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = 200 }, utils.elapsedMs(start)) catch {};
        }
    }

    pub fn build(container: *root.container, backend: Backend, opts: Options) !*NoSQL {
        const impl: *anyopaque = switch (backend) {
            .cassandra => blk: {
                const c = try root.NoSQLBackend.create(container.allocator, .{
                    .contact_points = opts.contact_points,
                    .keyspace = opts.keyspace,
                    .user = opts.user,
                    .password = opts.password,
                });
                break :blk @as(*anyopaque, c);
            },
            .couchbase => blk: {
                const cb = try root.Couchbase.create(container.allocator, .{
                    .contact_points = opts.contact_points,
                    .bucket = opts.keyspace,
                    .user = opts.user,
                    .password = opts.password,
                });
                break :blk @as(*anyopaque, cb);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{ .last_value = "" };
                break :blk @as(*anyopaque, mb);
            },
            .mongodb => blk: {
                const m = try root.MongoDB.create(container.allocator, .{
                    .contact_points = opts.contact_points,
                    .user = opts.user orelse "",
                    .pass = opts.password orelse "",
                    .auth_source = "admin",
                    .db = opts.keyspace,
                });
                break :blk @as(*anyopaque, m);
            },
        };
        const handle = try container.allocator.create(NoSQL);
        handle.* = NoSQL.init(impl, backend, null, container.metricz);
        return handle;
    }

    /// Free the type-erased handle and the backend implementation it wraps. The
    /// backend owns any connections / duplicated config strings it allocated, so
    /// each branch tears down the impl before the handle struct is destroyed.
    pub fn deinit(self: *NoSQL, allocator: std.mem.Allocator) void {
        switch (self.backend) {
            .cassandra => {
                const c = @as(*root.NoSQLBackend, @ptrCast(@alignCast(self.ptr)));
                c.conn.deinit();
                allocator.destroy(c);
            },
            .couchbase => {
                const cb = @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr)));
                cb.deinit(allocator);
            },
            .mongodb => {
                const m = @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr)));
                m.deinit(allocator);
            },
            .mock => {
                const mb = @as(*MockBackend, @ptrCast(@alignCast(self.ptr)));
                allocator.destroy(mb);
            },
        }
        allocator.destroy(self);
    }

    /// Fetch the first column of the first row returned by `query`, owned by
    /// `ctx.allocator`, or `null` when no row matches. Caller frees. The caller
    /// supplies the full CQL/N1QL statement (this dispatch layer builds nothing).
    pub fn get(self: *NoSQL, ctx: *root.Context, statement: []const u8) !?[]const u8 {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .cassandra => @as(*root.NoSQLBackend, @ptrCast(@alignCast(self.ptr))).get(ctx, statement),
            .couchbase => @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr))).get(ctx, statement),
            .mongodb => @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr))).get(ctx, statement),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).get(ctx, statement),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("get");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("get", start);
        return r;
    }

    /// Run a write statement (`query`). The result set is discarded.
    pub fn put(self: *NoSQL, ctx: *root.Context, statement: []const u8) !void {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .cassandra => @as(*root.NoSQLBackend, @ptrCast(@alignCast(self.ptr))).put(ctx, statement),
            .couchbase => @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr))).put(ctx, statement),
            .mongodb => @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr))).put(ctx, statement),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).put(ctx, statement),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("put");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("put", start);
        return r;
    }

    /// Run a DELETE statement (`query`). The result set is discarded.
    pub fn delete(self: *NoSQL, ctx: *root.Context, statement: []const u8) !void {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .cassandra => @as(*root.NoSQLBackend, @ptrCast(@alignCast(self.ptr))).delete(ctx, statement),
            .couchbase => @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr))).delete(ctx, statement),
            .mongodb => @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr))).delete(ctx, statement),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).delete(ctx, statement),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("delete");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("delete", start);
        return r;
    }

    /// Run an arbitrary backend-native statement (CQL / N1QL) and return the rows
    /// as a JSON array, owned by `ctx.allocator`. Caller frees.
    pub fn query(self: *NoSQL, ctx: *root.Context, statement: []const u8) ![]const u8 {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .cassandra => @as(*root.NoSQLBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, statement),
            .couchbase => @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr))).query(ctx, statement),
            .mongodb => @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr))).query(ctx, statement),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, statement),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("query");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("query", start);
        return r;
    }

    /// Return the last upstream failure recorded by the backend, if any. Call
    /// right after catching a `CouchbaseQueryFailed` error to read status/message
    /// (Couchbase is the zul-http NoSQL backend). The backend owns the `message`
    /// buffer (freed on the next call / `deinit`); the caller must read it, not
    /// free it. Other backends return `null`.
    pub fn lastError(self: *NoSQL) ?root.Error.DataSourceError {
        return switch (self.backend) {
            .couchbase => @as(*root.Couchbase, @ptrCast(@alignCast(self.ptr))).last_error,
            .mongodb => @as(*root.MongoDB, @ptrCast(@alignCast(self.ptr))).last_error,
            else => null,
        };
    }
};

/// Native-free backend used by tests to verify `NoSQL` dispatch.
pub const MockBackend = struct {
    gets: u32 = 0,
    puts: u32 = 0,
    deletes: u32 = 0,
    queries: u32 = 0,
    last_value: []const u8,

    pub fn get(self: *MockBackend, _: *root.Context, _: []const u8) !?[]const u8 {
        self.gets += 1;
        return null;
    }

    pub fn put(self: *MockBackend, _: *root.Context, _: []const u8) !void {
        self.puts += 1;
        self.last_value = "";
    }

    pub fn delete(self: *MockBackend, _: *root.Context, _: []const u8) !void {
        self.deletes += 1;
    }

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }
};

// ===================== Tests =====================

// test "NoSQL dispatches through the type-erased handle" {
//     var mock: MockBackend = .{ .last_value = "" };
//     var n = NoSQL.init(&mock, .mock, null, null);
//     var ctx_storage: root.Context = undefined;
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     ctx_storage.allocator = arena.allocator();

//     try n.put(&ctx_storage, "users", "alice", "{\"age\":30}");
//     try std.testing.expectEqual(@as(u32, 1), mock.puts);
//     try std.testing.expectEqualStrings("{\"age\":30}", mock.last_value);

//     _ = try n.get(&ctx_storage, "users", "alice");
//     try std.testing.expectEqual(@as(u32, 1), mock.gets);

//     try n.delete(&ctx_storage, "users", "alice");
//     try std.testing.expectEqual(@as(u32, 1), mock.deletes);

//     _ = try n.query(&ctx_storage, "users", "SELECT * FROM users");
//     try std.testing.expectEqual(@as(u32, 1), mock.queries);
// }
