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
        };
    }

    /// Last inserted row id (after an INSERT).
    pub fn lastInsertRowID(self: Interface) i64 {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).lastInsertRowID(),
        };
    }

    /// Number of rows affected by the last write statement.
    pub fn rowsAffected(self: Interface) usize {
        return switch (self.dialect) {
            .sqlite => @as(*SQLite, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
            .postgres => @as(*SQL, @ptrCast(@alignCast(self.ptr))).rowsAffected(),
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

test "datasource interface dispatches to sqlite with comptime Type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const log = try root.logger.create(allocator);
    defer allocator.destroy(log);
    const m = try root.metricz.initialize(allocator, .{ .prefix = "", .exclude = null });
    defer allocator.destroy(m);

    const sqlite = try root.SQLite.init(allocator, ":memory:", true, true, root.sqlitez.ThreadingMode.MultiThread, log, m);
    defer {
        sqlite.db.deinit();
        allocator.destroy(sqlite);
    }

    // Unified handle; the caller never names the concrete backend.
    const ds = Interface.init(sqlite, .sqlite);

    var ctx_storage: root.Context = undefined;
    ctx_storage.allocator = allocator;
    const ctx = &ctx_storage;

    _ = try ds.exec(ctx,
        \\CREATE TABLE IF NOT EXISTS person (id INTEGER PRIMARY KEY AUTOINCREMENT, age INTEGER NOT NULL)
    , .{});

    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 42)});
    const last = ds.lastInsertRowID();
    try std.testing.expectEqual(@as(i64, 1), last);

    const Person = struct { id: i64, age: i64 };

    // queryRow returns ?Type directly (was ?QueryRow before).
    const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expect(one != null);
    try std.testing.expectEqual(@as(i64, 42), one.?.age);

    // select alias of queryRow.
    const sel = try ds.select(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(i64, 42), sel.?.age);

    // query alias of queryRow.
    const q = try ds.query(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(i64, 42), q.?.age);

    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 7)});

    // queryRows returns an owned []Type.
    const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    // selectSlice appends into a caller-owned list.
    var list = std.array_list.Managed(Person).init(allocator);
    defer list.deinit();
    const n = try ds.selectSlice(ctx, Person, &list, "SELECT id, age FROM person ORDER BY id", .{});
    try std.testing.expectEqual(@as(i64, 2), n);

    _ = try ds.exec(ctx, "DELETE FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(usize, 1), ds.rowsAffected());
}
