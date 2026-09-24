const std = @import("std");
const root = @import("../zero.zig");

const SQLite = root.SQLite;
const SQL = root.SQL;
const service = root.circuit_breaker;

/// Supported database dialects. Resolved at runtime from `DB_DIALECT` so the
/// same `Interface` handle works for any configured backend without the caller
/// knowing which one is active. Add new dialects here (e.g. mysql) and a case
/// in the dialect switch as backends are implemented.
pub const Dialect = enum {
    sqlite,
    postgres,
    /// In-process OLAP SQL engine (DuckDB). Reuses this relational interface;
    /// backed by `src/datasource/DuckDB.zig` (links `libs/libduckdb.so`).
    duckdb,
    /// Columnar OLAP SQL engine (ClickHouse) over HTTP. Reuses this relational
    /// interface; backed by `src/datasource/ClickHouse.zig` (HTTP via `zul`,
    /// no native driver). Transactions/lastInsertRowID are no-ops (eventually
    /// consistent).
    clickhouse,
    /// Test-only dialect backed by `MockBackend`. Lets the `Interface` dispatch
    /// be exercised without loading a real database driver (keeps the
    /// coverage/unit-test build free of the native `libsqlite3` dependency that
    /// aborts under kcov's ptrace, which otherwise blanks the whole report).
    mock,
};

/// Native-free backend used by tests to verify `Interface` dispatch. It records
/// the calls made through the type-erased `Interface` so tests can assert that
/// dispatch reached the right method, without touching a real database.
pub const MockBackend = struct {
    query_row_calls: u32 = 0,
    query_rows_calls: u32 = 0,
    query_row_context_calls: u32 = 0,
    query_rows_context_calls: u32 = 0,
    select_slice_calls: u32 = 0,
    exec_calls: u32 = 0,
    last_id: i64 = 1,
    affected: usize = 1,

    pub fn queryRow(self: *MockBackend, _: *root.Context, comptime Type: type, comptime _: []const u8, _: anytype) !?Type {
        self.query_row_calls += 1;
        return null;
    }

    pub fn queryRows(self: *MockBackend, ctx: *root.Context, comptime Type: type, comptime _: []const u8, _: anytype) ![]Type {
        self.query_rows_calls += 1;
        return try ctx.allocator.alloc(Type, 0);
    }

    pub fn queryRowContext(self: *MockBackend, _: *root.Context, comptime Type: type, comptime _: []const u8, _: anytype) !?Type {
        self.query_row_context_calls += 1;
        return null;
    }

    pub fn queryRowsContext(self: *MockBackend, ctx: *root.Context, comptime Type: type, comptime _: []const u8, _: anytype) ![]Type {
        self.query_rows_context_calls += 1;
        return try ctx.allocator.alloc(Type, 0);
    }

    pub fn selectSlice(self: *MockBackend, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime stmt: []const u8, args: anytype) !i64 {
        const rows = try self.queryRowsContext(ctx, Type, stmt, args);
        for (rows) |r| {
            try list.append(r);
        }
        self.select_slice_calls += 1;
        return @intCast(list.items.len);
    }

    pub fn execWithContext(self: *MockBackend, _: *root.Context, comptime _: []const u8, _: anytype) !i64 {
        self.exec_calls += 1;
        return self.last_id;
    }

    pub fn lastInsertRowID(self: *MockBackend) i64 {
        return self.last_id;
    }

    pub fn rowsAffected(self: *MockBackend) usize {
        return self.affected;
    }

    pub fn begin(self: *MockBackend) !void {
        _ = self;
    }

    pub fn commit(self: *MockBackend) !void {
        _ = self;
    }

    pub fn rollback(self: *MockBackend) void {
        _ = self;
    }
};

/// Unified, type-erased datasource interface.
///
/// Usage (mirrors `ctx.SQL`):
///   const user = try ctx.SQL.queryRow(User, "SELECT ...", .{});
///   const rows = try ctx.SQL.queryRows(User, alloc, "SELECT ...", .{});
///   try ctx.SQL.selectSlice(User, &list, "SELECT ...", .{});
pub const Interface = struct {
    ptr: *anyopaque,
    dialect: Dialect,
    /// Optional circuit breaker guarding all backend calls. When `null`, calls
    /// pass straight through (no trip/fail-fast). Enable via `SQL_CIRCUIT_BREAKER_ENABLE`.
    breaker: ?service.CircuitBreaker = null,

    /// Build an interface handle from a concrete backend pointer.
    pub fn init(ptr: anytype, dialect: Dialect, breaker: ?service.CircuitBreaker) Interface {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .dialect = dialect,
            .breaker = breaker,
        };
    }

    /// Single typed row. `null` when the query matches no rows.
    pub fn queryRow(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).queryRow(
                ctx,
                Type,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).queryRow(
                ctx,
                Type,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).queryRow(
                ctx,
                Type,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).queryRow(
                ctx,
                Type,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).queryRow(
                ctx,
                Type,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Multiple typed rows, owned by the connection allocator.
    pub fn queryRows(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).queryRows(
                ctx,
                Type,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).queryRows(
                ctx,
                Type,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).queryRows(
                ctx,
                Type,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).queryRows(
                ctx,
                Type,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).queryRows(
                ctx,
                Type,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Single typed row with a request context (tracing / metrics).
    pub fn queryRowContext(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).queryRowContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).queryRowContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).queryRowContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).queryRowContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).queryRowContext(
                ctx,
                Type,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Multiple typed rows with a request context.
    pub fn queryRowsContext(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).queryRowsContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).queryRowsContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).queryRowsContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).queryRowsContext(
                ctx,
                Type,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).queryRowsContext(
                ctx,
                Type,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Append typed rows into `list`. Returns the number of rows appended.
    pub fn selectSlice(self: *Interface, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime stmt: []const u8, args: anytype) !i64 {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).selectSlice(
                ctx,
                Type,
                list,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).selectSlice(
                ctx,
                Type,
                list,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).selectSlice(
                ctx,
                Type,
                list,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).selectSlice(
                ctx,
                Type,
                list,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).selectSlice(
                ctx,
                Type,
                list,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Execute a write statement (INSERT/UPDATE/DELETE). Returns the last insert id.
    pub fn exec(self: *Interface, ctx: *root.Context, comptime stmt: []const u8, args: anytype) !i64 {
        if (self.breaker) |*b| {
            b.before() catch return error.CircuitOpen;
        }
        const r = switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).execWithContext(
                ctx,
                stmt,
                args,
            ),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).execWithContext(
                ctx,
                stmt,
                args,
            ),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).execWithContext(
                ctx,
                stmt,
                args,
            ),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).execWithContext(
                ctx,
                stmt,
                args,
            ),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).execWithContext(
                ctx,
                stmt,
                args,
            ),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        return r;
    }

    /// Last inserted row id (after an INSERT).
    pub fn lastInsertRowID(self: Interface) i64 {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
        };
    }

    /// Number of rows affected by the last write statement.
    pub fn rowsAffected(self: Interface) usize {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
        };
    }

    /// Begin a transaction on the underlying backend.
    pub fn begin(self: Interface) !void {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).begin(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).begin(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).begin(),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).begin(),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).begin(),
        };
    }

    /// Commit the active transaction.
    pub fn commit(self: Interface) !void {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).commit(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).commit(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).commit(),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).commit(),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).commit(),
        };
    }

    /// Roll back the active transaction (best-effort).
    pub fn rollback(self: Interface) void {
        switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).rollback(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).rollback(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).rollback(),
            .duckdb => @as(*root.DuckDB, @ptrCast(@alignCast(self.ptr))).rollback(),
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).rollback(),
        }
    }

    /// `query` alias — single typed row.
    pub fn query(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }

    /// `select` alias — single typed row.
    pub fn select(self: *Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }

    /// Return the last upstream failure recorded by the backend, if any. Call
    /// right after catching a `ClickHouseQueryFailed` error to read status/message
    /// (ClickHouse is the zul-http relational backend). All other backends
    /// (Postgres, SQLite, DuckDB, mock) return `null` — their error handling is
    /// untouched. The backend owns the `message` buffer (freed on the next call /
    /// `deinit`); the caller must read it, not free it.
    pub fn lastError(self: Interface) ?root.Error.DataSourceError {
        return switch (self.dialect) {
            .clickhouse => @as(*root.ClickHouse, @ptrCast(@alignCast(self.ptr))).last_error,
            else => null,
        };
    }
};

// test "datasource interface dispatches through the type-erased handle" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();

//     // Native-free backend: exercises the dispatch without loading a real
//     // database driver (which aborts under kcov's ptrace and blanks coverage).
//     var mock: MockBackend = .{};
//     const ds = Interface.init(&mock, .mock);

//     var ctx_storage: root.Context = undefined;
//     ctx_storage.allocator = allocator;
//     const ctx = &ctx_storage;

//     // exec -> execWithContext
//     _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 42)});
//     try std.testing.expectEqual(@as(u32, 1), mock.exec_calls);
//     try std.testing.expectEqual(@as(i64, 1), ds.lastInsertRowID());

//     const Person = struct { id: i64, age: i64 };

//     // queryRow -> MockBackend.queryRow
//     const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
//     try std.testing.expectEqual(@as(u32, 1), mock.query_row_calls);
//     try std.testing.expect(one == null);

//     // select alias of queryRow.
//     _ = try ds.select(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
//     try std.testing.expectEqual(@as(u32, 2), mock.query_row_calls);

//     // query alias of queryRow.
//     _ = try ds.query(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
//     try std.testing.expectEqual(@as(u32, 3), mock.query_row_calls);

//     // queryRows -> MockBackend.queryRows (owned, freeable slice).
//     const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
//     defer allocator.free(rows);
//     try std.testing.expectEqual(@as(u32, 1), mock.query_rows_calls);
//     try std.testing.expectEqual(@as(usize, 0), rows.len);

//     // selectSlice -> MockBackend.selectSlice.
//     var list = std.array_list.Managed(Person).init(allocator);
//     defer list.deinit();
//     const n = try ds.selectSlice(ctx, Person, &list, "SELECT id, age FROM person ORDER BY id", .{});
//     try std.testing.expectEqual(@as(u32, 1), mock.select_slice_calls);
//     try std.testing.expectEqual(@as(i64, 0), n);

//     // second exec -> rowsAffected.
//     _ = try ds.exec(ctx, "DELETE FROM person WHERE id = ?", .{@as(i64, 1)});
//     try std.testing.expectEqual(@as(u32, 2), mock.exec_calls);
//     try std.testing.expectEqual(@as(usize, 1), ds.rowsAffected());
// }
