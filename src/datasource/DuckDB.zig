const std = @import("std");
const root = @import("../zero.zig");
const c = @import("cduckdb.zig");

/// DuckDB in-process OLAP backend (relational SQL). Wraps the DuckDB C API
/// (`libs/libduckdb.so`) and maps result columns onto caller struct fields by
/// name, so it slots into the existing `Datasource` SQL interface unchanged.
pub const DuckDB = struct {
    allocator: std.mem.Allocator,
    db: c.duckdb_database,
    conn: c.duckdb_connection,

    pub fn create(allocator: std.mem.Allocator, path: []const u8) !*DuckDB {
        const open_path = if (path.len == 0) "" else path;
        const cpath = try c.toCStr(allocator, open_path);
        defer allocator.free(cpath);

        var db: c.duckdb_database = undefined;
        if (c.duckdb_open(cpath, &db) != 0) return error.DuckDBOpenFailed;

        var conn: c.duckdb_connection = undefined;
        if (c.duckdb_connect(db, &conn) != 0) {
            c.duckdb_close(&db);
            return error.DuckDBConnectFailed;
        }

        const self = try allocator.create(DuckDB);
        self.* = .{ .allocator = allocator, .db = db, .conn = conn };
        return self;
    }

    pub fn close(self: *DuckDB) void {
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
    }

    /// Run `sql`. When `args` is non-empty it is treated as a tuple of positional
    /// `?` bind parameters and a prepared statement is used; otherwise the SQL is
    /// executed directly. This lets callers pass runtime values safely.
    fn run(self: *DuckDB, comptime sql: []const u8, args: anytype, result: *c.duckdb_result) !void {
        const has_args = comptime @typeInfo(@TypeOf(args)) == .@"struct" and
            @typeInfo(@TypeOf(args)).@"struct".fields.len > 0;
        if (!has_args) {
            const cstr = try c.toCStr(self.allocator, sql);
            defer self.allocator.free(cstr);
            if (c.duckdb_query(self.conn, cstr, result) != 0) {
                c.duckdb_destroy_result(result);
                return error.DuckDBQueryFailed;
            }
            return;
        }

        var ps: c.duckdb_prepared_statement = undefined;
        const cstr = try c.toCStr(self.allocator, sql);
        defer self.allocator.free(cstr);
        if (c.duckdb_prepare(self.conn, cstr, &ps) != 0) {
            c.duckdb_destroy_prepare(&ps);
            return error.DuckDBQueryFailed;
        }
        defer c.duckdb_destroy_prepare(&ps);

        inline for (@typeInfo(@TypeOf(args)).@"struct".fields, 0..) |f, i| {
            try self.bindValue(&ps, @intCast(i + 1), @field(args, f.name));
        }

        if (c.duckdb_execute_prepared(ps, result) != 0) {
            c.duckdb_destroy_result(result);
            return error.DuckDBQueryFailed;
        }
    }

    fn bindValue(self: *DuckDB, ps: *c.duckdb_prepared_statement, idx: c.idx_t, v: anytype) !void {
        const T = @TypeOf(v);
        const info = @typeInfo(T);
        if (info == .optional) {
            if (v == null) {
                if (c.duckdb_bind_null(ps.*, idx) != 0) return error.DuckDBQueryFailed;
                return;
            }
            return self.bindValue(ps, idx, v.?);
        }
        switch (info) {
            .int, .comptime_int => {
                if (c.duckdb_bind_int64(ps.*, idx, @intCast(v)) != 0) return error.DuckDBQueryFailed;
            },
            .float, .comptime_float => {
                if (c.duckdb_bind_double(ps.*, idx, @floatCast(v)) != 0) return error.DuckDBQueryFailed;
            },
            .bool => {
                if (c.duckdb_bind_boolean(ps.*, idx, v) != 0) return error.DuckDBQueryFailed;
            },
            .pointer => |p| if (p.size == .slice and p.child == u8) {
                const s = try c.toCStr(self.allocator, v);
                defer self.allocator.free(s);
                if (c.duckdb_bind_varchar(ps.*, idx, s) != 0) return error.DuckDBQueryFailed;
            } else @compileError("DuckDB: unsupported bind pointer type " ++ @typeName(T)),
            else => @compileError("DuckDB: unsupported bind type " ++ @typeName(T)),
        }
    }

    pub fn queryRow(self: *DuckDB, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        var result: c.duckdb_result = undefined;
        try self.run(stmt, args, &result);
        defer c.duckdb_destroy_result(&result);
        if (c.duckdb_row_count(&result) == 0) return null;
        return try mapRow(Type, &result, 0, ctx.allocator);
    }

    pub fn queryRows(self: *DuckDB, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        var result: c.duckdb_result = undefined;
        try self.run(stmt, args, &result);
        defer c.duckdb_destroy_result(&result);
        const rows = c.duckdb_row_count(&result);
        const out = try ctx.allocator.alloc(Type, rows);
        var i: c.idx_t = 0;
        while (i < rows) : (i += 1) {
            out[i] = try mapRow(Type, &result, i, ctx.allocator);
        }
        return out;
    }

    pub fn queryRowContext(self: *DuckDB, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }

    pub fn queryRowsContext(self: *DuckDB, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        return self.queryRows(ctx, Type, stmt, args);
    }

    pub fn selectSlice(self: *DuckDB, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime stmt: []const u8, args: anytype) !i64 {
        const rows = try self.queryRows(ctx, Type, stmt, args);
        for (rows) |r| try list.append(r);
        return @intCast(list.items.len);
    }

    pub fn execWithContext(self: *DuckDB, _: *root.Context, comptime stmt: []const u8, args: anytype) !i64 {
        var result: c.duckdb_result = undefined;
        try self.run(stmt, args, &result);
        c.duckdb_destroy_result(&result);
        return 0;
    }

    pub fn lastInsertRowID(self: *DuckDB) i64 {
        _ = self;
        return 0;
    }

    pub fn rowsAffected(self: *DuckDB) usize {
        _ = self;
        return 0;
    }

    pub fn begin(self: *DuckDB) !void {
        var result: c.duckdb_result = undefined;
        try self.run("BEGIN TRANSACTION", .{}, &result);
        c.duckdb_destroy_result(&result);
    }

    pub fn commit(self: *DuckDB) !void {
        var result: c.duckdb_result = undefined;
        try self.run("COMMIT", .{}, &result);
        c.duckdb_destroy_result(&result);
    }

    pub fn rollback(self: *DuckDB) void {
        var result: c.duckdb_result = undefined;
        self.run("ROLLBACK", .{}, &result) catch {};
        c.duckdb_destroy_result(&result);
    }
};

fn findColumn(result: *c.duckdb_result, col_count: c.idx_t, name: []const u8) ?c.idx_t {
    var i: c.idx_t = 0;
    while (i < col_count) : (i += 1) {
        const cn = std.mem.span(c.duckdb_column_name(result, i));
        if (std.ascii.eqlIgnoreCase(name, cn)) return i;
    }
    return null;
}

fn readValue(comptime T: type, result: *c.duckdb_result, col: c.idx_t, row: c.idx_t, alloc: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        return try readValue(info.optional.child, result, col, row, alloc);
    }
    return switch (info) {
        .int => @intCast(c.duckdb_value_int64(result, col, row)),
        .float => @floatCast(c.duckdb_value_double(result, col, row)),
        .bool => c.duckdb_value_boolean(result, col, row),
        .pointer => |p| if (p.size == .slice and p.child == u8) blk: {
            const s = c.duckdb_value_string(result, col, row);
            defer if (s.data) |d| c.duckdb_free(d);
            if (s.size == 0 or s.data == null) break :blk try alloc.dupe(u8, "");
            break :blk try alloc.dupe(u8, s.data.?[0..s.size]);
        } else @compileError("DuckDB: unsupported pointer field type"),
        else => @compileError("DuckDB: unsupported field type " ++ @typeName(T)),
    };
}

fn mapRow(comptime Type: type, result: *c.duckdb_result, row: c.idx_t, alloc: std.mem.Allocator) !Type {
    const ti = @typeInfo(Type);
    if (ti != .@"struct") @compileError("DuckDB queryRow requires a struct type, got " ++ @typeName(Type));

    var value: Type = undefined;
    const col_count = c.duckdb_column_count(result);
    inline for (ti.@"struct".fields) |field| {
        const col = findColumn(result, col_count, field.name) orelse return error.ColumnNotFound;
        if (c.duckdb_value_is_null(result, col, row)) {
            if (@typeInfo(field.type) == .optional) {
                @field(value, field.name) = null;
            } else {
                return error.NonNullColumnIsNull;
            }
            continue;
        }
        @field(value, field.name) = try readValue(field.type, result, col, row, alloc);
    }
    return value;
}

// ===================== Tests =====================

// test "DuckDB in-memory query maps onto a struct" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();

//     var db = try DuckDB.create(allocator, "");
//     defer db.close();

//     {
//         var r1: c.duckdb_result = undefined;
//         try db.run("CREATE TABLE users (id INTEGER, name VARCHAR)", .{}, &r1);
//         c.duckdb_destroy_result(&r1);
//         var r2: c.duckdb_result = undefined;
//         try db.run("INSERT INTO users VALUES (1, 'alice'), (2, 'bob')", .{}, &r2);
//         c.duckdb_destroy_result(&r2);
//     }

//     var ctx: root.Context = undefined;
//     ctx.allocator = allocator;

//     const User = struct { id: i32, name: []const u8 };
//     const one = (try db.queryRow(&ctx, User, "SELECT id, name FROM users WHERE id = 1", .{})).?;
//     try std.testing.expectEqual(@as(i32, 1), one.id);
//     try std.testing.expectEqualStrings("alice", one.name);

//     const all = try db.queryRows(&ctx, User, "SELECT id, name FROM users ORDER BY id", .{});
//     try std.testing.expectEqual(@as(usize, 2), all.len);
//     try std.testing.expectEqual(@as(i32, 2), all[1].id);
// }
