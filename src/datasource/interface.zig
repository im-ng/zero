const std = @import("std");
const root = @import("../zero.zig");

const SQLite = root.SQLite;
const SQL = root.SQL;

/// Supported database dialects. Resolved at runtime from `DB_DIALECT` so the
/// same `Interface` handle works for any configured backend without the caller
/// knowing which one is active. Add new dialects here (e.g. mysql) and a case
/// in the dialect switch as backends are implemented.
pub const Dialect = enum {
    sqlite,
    postgres,
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
        for (rows) |r| try list.append(r);
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

    /// Build an interface handle from a concrete backend pointer.
    pub fn init(ptr: anytype, dialect: Dialect) Interface {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .dialect = dialect,
        };
    }

    /// Single typed row. `null` when the query matches no rows.
    pub fn queryRow(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return switch (self.dialect) {
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
        };
    }

    /// Multiple typed rows, owned by the connection allocator.
    pub fn queryRows(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        return switch (self.dialect) {
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
        };
    }

    /// Single typed row with a request context (tracing / metrics).
    pub fn queryRowContext(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return switch (self.dialect) {
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
        };
    }

    /// Multiple typed rows with a request context.
    pub fn queryRowsContext(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        return switch (self.dialect) {
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
        };
    }

    /// Append typed rows into `list`. Returns the number of rows appended.
    pub fn selectSlice(self: Interface, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime stmt: []const u8, args: anytype) !i64 {
        return switch (self.dialect) {
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
        };
    }

    /// Execute a write statement (INSERT/UPDATE/DELETE). Returns the last insert id.
    pub fn exec(self: Interface, ctx: *root.Context, comptime stmt: []const u8, args: anytype) !i64 {
        return switch (self.dialect) {
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
        };
    }

    /// Last inserted row id (after an INSERT).
    pub fn lastInsertRowID(self: Interface) i64 {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
        };
    }

    /// Number of rows affected by the last write statement.
    pub fn rowsAffected(self: Interface) usize {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
        };
    }

    /// `query` alias — single typed row.
    pub fn query(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }

    /// `select` alias — single typed row.
    pub fn select(self: Interface, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }
};

test "datasource interface dispatches through the type-erased handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Native-free backend: exercises the dispatch without loading a real
    // database driver (which aborts under kcov's ptrace and blanks coverage).
    var mock: MockBackend = .{};
    const ds = Interface.init(&mock, .mock);

    var ctx_storage: root.Context = undefined;
    ctx_storage.allocator = allocator;
    const ctx = &ctx_storage;

    // exec -> execWithContext
    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 42)});
    try std.testing.expectEqual(@as(u32, 1), mock.exec_calls);
    try std.testing.expectEqual(@as(i64, 1), ds.lastInsertRowID());

    const Person = struct { id: i64, age: i64 };

    // queryRow -> MockBackend.queryRow
    const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
    try std.testing.expectEqual(@as(u32, 1), mock.query_row_calls);
    try std.testing.expect(one == null);

    // select alias of queryRow.
    _ = try ds.select(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
    try std.testing.expectEqual(@as(u32, 2), mock.query_row_calls);

    // query alias of queryRow.
    _ = try ds.query(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{@as(i64, 1)});
    try std.testing.expectEqual(@as(u32, 3), mock.query_row_calls);

    // queryRows -> MockBackend.queryRows (owned, freeable slice).
    const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(u32, 1), mock.query_rows_calls);
    try std.testing.expectEqual(@as(usize, 0), rows.len);

    // selectSlice -> MockBackend.selectSlice.
    var list = std.array_list.Managed(Person).init(allocator);
    defer list.deinit();
    const n = try ds.selectSlice(ctx, Person, &list, "SELECT id, age FROM person ORDER BY id", .{});
    try std.testing.expectEqual(@as(u32, 1), mock.select_slice_calls);
    try std.testing.expectEqual(@as(i64, 0), n);

    // second exec -> rowsAffected.
    _ = try ds.exec(ctx, "DELETE FROM person WHERE id = ?", .{@as(i64, 1)});
    try std.testing.expectEqual(@as(u32, 2), mock.exec_calls);
    try std.testing.expectEqual(@as(usize, 1), ds.rowsAffected());
}
