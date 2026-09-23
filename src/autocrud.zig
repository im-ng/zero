const std = @import("std");
const root = @import("zero.zig");

const App = root.App;
const Context = root.Context;
const SQL = root.SQL;
const SQLite = root.SQLite;
const DuckDB = root.DuckDB;
const ClickHouse = root.ClickHouse;
const Datasource = root.Datasource;
const MockBackend = root.datasourceInterface.MockBackend;

/// Options for `addRestHandlers`. `resource` is the URL segment (e.g. `"users"`
/// registers `/users`, `/users/:id`, …). `table` defaults to `resource`; the
/// primary key is `id` unless `id_field` says otherwise.
pub const AutoCrudOptions = struct {
    resource: []const u8,
    table: []const u8 = "",
    id_field: []const u8 = "id",
};

fn tupleTypes(comptime T: type, comptime skip_id: ?usize) []const type {
    const fields = @typeInfo(T).@"struct".fields;
    comptime var arr: [fields.len]type = undefined;
    comptime var k: usize = 0;
    inline for (fields, 0..) |f, i| {
        if (skip_id) |s| if (i == s) continue;
        arr[k] = f.type;
        k += 1;
    }
    if (skip_id) |s| {
        arr[k] = fields[s].type;
    }
    return &arr;
}

fn toTuple(comptime T: type, obj: T, comptime skip_id: ?usize) std.meta.Tuple(tupleTypes(T, skip_id)) {
    var r: std.meta.Tuple(tupleTypes(T, skip_id)) = undefined;
    comptime var dst: usize = 0;
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        if (skip_id) |s| if (i == s) continue;
        r[dst] = @field(obj, f.name);
        dst += 1;
    }
    if (skip_id) |s| {
        r[dst] = @field(obj, @typeInfo(T).@"struct".fields[s].name);
    }
    return r;
}

fn parseId(comptime IdType: type, raw: []const u8) !IdType {
    return switch (@typeInfo(IdType)) {
        .int, .comptime_int => std.fmt.parseInt(IdType, raw, 10),
        .pointer => |p| if (p.child == u8) raw,
        else => @compileError("AutoCrud: unsupported id type " ++ @typeName(IdType)),
    };
}

const Stmts = struct {
    insert_pg: []const u8,
    insert_q: []const u8,
    get_pg: []const u8,
    get_q: []const u8,
    list: []const u8,
    update_pg: []const u8,
    update_q: []const u8,
    delete_pg: []const u8,
    delete_q: []const u8,
};

fn buildStmts(comptime T: type, comptime table: []const u8, comptime id_field: []const u8, id_idx: usize) Stmts {
    const fields = @typeInfo(T).@"struct".fields;
    const n = fields.len;

    comptime var c: []const u8 = "";
    inline for (fields, 0..) |f, i| {
        if (i > 0) c = c ++ ",";
        c = c ++ f.name;
    }

    comptime var pgph: []const u8 = "";
    inline for (0..n) |i| {
        if (i > 0) pgph = pgph ++ ",";
        pgph = pgph ++ std.fmt.comptimePrint("${d}", .{i + 1});
    }

    comptime var qph: []const u8 = "";
    inline for (0..n) |i| {
        if (i > 0) qph = qph ++ ",";
        qph = qph ++ "?";
    }

    comptime var set_pg: []const u8 = "";
    comptime var set_q: []const u8 = "";
    var p: usize = 0;
    inline for (fields, 0..) |f, i| {
        if (i == id_idx) continue;
        p += 1;
        if (p > 1) {
            set_pg = set_pg ++ ",";
            set_q = set_q ++ ",";
        }
        set_pg = set_pg ++ f.name ++ std.fmt.comptimePrint("=${d}", .{p});
        set_q = set_q ++ f.name ++ "=?";
    }

    const non_id = n - 1;
    return .{
        .insert_pg = "INSERT INTO " ++ table ++ " (" ++ c ++ ") VALUES (" ++ pgph ++ ")",
        .insert_q = "INSERT INTO " ++ table ++ " (" ++ c ++ ") VALUES (" ++ qph ++ ")",
        .get_pg = "SELECT " ++ c ++ " FROM " ++ table ++ " WHERE " ++ id_field ++ " = $1",
        .get_q = "SELECT " ++ c ++ " FROM " ++ table ++ " WHERE " ++ id_field ++ " = ?",
        .list = "SELECT " ++ c ++ " FROM " ++ table ++ " LIMIT 100",
        .update_pg = "UPDATE " ++ table ++ " SET " ++ set_pg ++ " WHERE " ++ id_field ++ " = $" ++ std.fmt.comptimePrint("{d}", .{non_id + 1}),
        .update_q = "UPDATE " ++ table ++ " SET " ++ set_q ++ " WHERE " ++ id_field ++ " = ?",
        .delete_pg = "DELETE FROM " ++ table ++ " WHERE " ++ id_field ++ " = $1",
        .delete_q = "DELETE FROM " ++ table ++ " WHERE " ++ id_field ++ " = ?",
    };
}

fn backendPg(ctx: *Context) *SQL {
    return @as(*SQL, @ptrCast(@alignCast(ctx.SQL.ptr)));
}

fn backendSqlite(ctx: *Context) *SQLite {
    return @as(*SQLite, @ptrCast(@alignCast(ctx.SQL.ptr)));
}

fn backendDuckDB(ctx: *Context) *DuckDB {
    return @as(*DuckDB, @ptrCast(@alignCast(ctx.SQL.ptr)));
}

fn backendClickHouse(ctx: *Context) *ClickHouse {
    return @as(*ClickHouse, @ptrCast(@alignCast(ctx.SQL.ptr)));
}

fn listHandler(comptime T: type, comptime st: Stmts) *const fn (*Context) anyerror!void {
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            switch (ctx.SQL.dialect) {
                .postgres => {
                    const rows = try backendPg(ctx).queryRows(ctx, T, st.list, .{});
                    try ctx.json(rows);
                },
                .sqlite => {
                    const rows = try backendSqlite(ctx).queryRows(ctx, T, st.list, .{});
                    try ctx.json(rows);
                },
                .duckdb => {
                    const rows = try backendDuckDB(ctx).queryRows(ctx, T, st.list, .{});
                    try ctx.json(rows);
                },
                .clickhouse => {
                    const rows = try backendClickHouse(ctx).queryRows(ctx, T, st.list, .{});
                    try ctx.json(rows);
                },
                .mock => {
                    const rows = try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).queryRows(ctx, T, st.list, .{});
                    try ctx.json(rows);
                },
            }
        }
    };
    return &impl.call;
}

fn getHandler(comptime T: type, comptime st: Stmts, comptime id_idx: usize) *const fn (*Context) anyerror!void {
    const IdType = @typeInfo(T).@"struct".fields[id_idx].type;
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const raw = ctx.param("id");
            const idv = parseId(IdType, raw) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid id" });
                return;
            };
            const row = switch (ctx.SQL.dialect) {
                .postgres => try backendPg(ctx).queryRow(ctx, T, st.get_pg, .{idv}),
                .sqlite => try backendSqlite(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .duckdb => try backendDuckDB(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .clickhouse => try backendClickHouse(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .mock => try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).queryRow(ctx, T, st.get_q, .{idv}),
            };
            if (row) |r| {
                try ctx.json(r);
            } else {
                ctx.response.setStatus(.not_found);
                try ctx.json(.{ .err = "not found" });
            }
        }
    };
    return &impl.call;
}

fn createHandler(comptime T: type, comptime st: Stmts) *const fn (*Context) anyerror!void {
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const parsed = ctx.bind(T) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid json" });
                return;
            };
            const o = parsed orelse {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "body required" });
                return;
            };
            const args = toTuple(T, o, null);
            switch (ctx.SQL.dialect) {
                .postgres => _ = try backendPg(ctx).execWithContext(ctx, st.insert_pg, args),
                .sqlite => _ = try backendSqlite(ctx).execWithContext(ctx, st.insert_q, args),
                .duckdb => _ = try backendDuckDB(ctx).execWithContext(ctx, st.insert_q, args),
                .clickhouse => _ = try backendClickHouse(ctx).execWithContext(ctx, st.insert_q, args),
                .mock => _ = try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).execWithContext(ctx, st.insert_q, args),
            }
            try ctx.json(o);
            ctx.response.setStatus(.created);
        }
    };
    return &impl.call;
}

fn updateHandler(comptime T: type, comptime st: Stmts, comptime id_idx: usize) *const fn (*Context) anyerror!void {
    const IdType = @typeInfo(T).@"struct".fields[id_idx].type;
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const raw = ctx.param("id");
            const idv = parseId(IdType, raw) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid id" });
                return;
            };
            const parsed = ctx.bind(T) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid json" });
                return;
            };
            const o = parsed orelse {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "body required" });
                return;
            };
            const args = toTuple(T, o, id_idx);
            const updated = switch (ctx.SQL.dialect) {
                .postgres => (try backendPg(ctx).execWithContext(ctx, st.update_pg, args)) > 0,
                .sqlite => (try backendSqlite(ctx).execWithContext(ctx, st.update_q, args)) > 0,
                .duckdb => (try backendDuckDB(ctx).execWithContext(ctx, st.update_q, args)) > 0,
                .clickhouse => (try backendClickHouse(ctx).execWithContext(ctx, st.update_q, args)) > 0,
                .mock => (try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).execWithContext(ctx, st.update_q, args)) > 0,
            };
            if (!updated) {
                ctx.response.setStatus(.not_found);
                try ctx.json(.{ .err = "not found" });
                return;
            }
            const row = switch (ctx.SQL.dialect) {
                .postgres => try backendPg(ctx).queryRow(ctx, T, st.get_pg, .{idv}),
                .sqlite => try backendSqlite(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .duckdb => try backendDuckDB(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .clickhouse => try backendClickHouse(ctx).queryRow(ctx, T, st.get_q, .{idv}),
                .mock => try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).queryRow(ctx, T, st.get_q, .{idv}),
            };
            if (row) |r| {
                try ctx.json(r);
            } else {
                ctx.response.setStatus(.not_found);
                try ctx.json(.{ .err = "not found" });
            }
        }
    };
    return &impl.call;
}

fn deleteHandler(comptime T: type, comptime st: Stmts, comptime id_idx: usize) *const fn (*Context) anyerror!void {
    const IdType = @typeInfo(T).@"struct".fields[id_idx].type;
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const raw = ctx.param("id");
            const idv = parseId(IdType, raw) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid id" });
                return;
            };
            const affected = switch (ctx.SQL.dialect) {
                .postgres => blk: {
                    _ = try backendPg(ctx).execWithContext(ctx, st.delete_pg, .{idv});
                    break :blk backendPg(ctx).rowsAffected();
                },
                .sqlite => blk: {
                    _ = try backendSqlite(ctx).execWithContext(ctx, st.delete_q, .{idv});
                    break :blk backendSqlite(ctx).rowsAffected();
                },
                .duckdb => blk: {
                    _ = try backendDuckDB(ctx).execWithContext(ctx, st.delete_q, .{idv});
                    break :blk backendDuckDB(ctx).rowsAffected();
                },
                .clickhouse => blk: {
                    _ = try backendClickHouse(ctx).execWithContext(ctx, st.delete_q, .{idv});
                    break :blk backendClickHouse(ctx).rowsAffected();
                },
                .mock => blk: {
                    _ = try @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).execWithContext(ctx, st.delete_q, .{idv});
                    break :blk @as(*MockBackend, @ptrCast(@alignCast(ctx.SQL.ptr))).rowsAffected();
                },
            };
            if (affected == 0) {
                ctx.response.setStatus(.not_found);
                try ctx.json(.{ .err = "not found" });
            } else {
                try ctx.json(.{ .deleted = affected });
            }
        }
    };
    return &impl.call;
}

/// Registers list/get/create/update/delete REST handlers for struct `T` against
/// the configured SQL datasource (Postgres, SQLite, or DuckDB — all are
/// generated and dispatched at runtime on `ctx.SQL.dialect`).
pub fn addRestHandlers(self: *App, comptime T: type, comptime opts: AutoCrudOptions) !void {
    const table = if (opts.table.len > 0) opts.table else opts.resource;
    const id_field = opts.id_field;

    const fields = @typeInfo(T).@"struct".fields;
    comptime var id_idx: ?usize = null;
    inline for (fields, 0..) |f, i| {
        if (comptime std.mem.eql(u8, f.name, id_field)) id_idx = i;
    }
    if (id_idx == null) {
        @compileError("AutoCrud: struct " ++ @typeName(T) ++ " has no field '" ++ id_field ++ "'");
    }
    const IDX = id_idx.?;

    const st = comptime buildStmts(T, table, id_field, IDX);
    const base = "/" ++ opts.resource;

    try self.get(base, comptime listHandler(T, st));
    try self.get(base ++ "/:id", comptime getHandler(T, st, IDX));
    try self.post(base, comptime createHandler(T, st));
    try self.put(base ++ "/:id", comptime updateHandler(T, st, IDX));
    try self.delete(base ++ "/:id", comptime deleteHandler(T, st, IDX));
}

const Sample = struct { id: i64, name: []const u8, email: []const u8 };

// ===================== Tests =====================

test "AutoCrud generates dialect-correct SQL" {
    const st = comptime buildStmts(Sample, "users", "id", 0);
    try std.testing.expectEqualStrings(
        "INSERT INTO users (id,name,email) VALUES ($1,$2,$3)",
        st.insert_pg,
    );
    try std.testing.expectEqualStrings(
        "INSERT INTO users (id,name,email) VALUES (?,?,?)",
        st.insert_q,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM users WHERE id = $1",
        st.get_pg,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM users WHERE id = ?",
        st.get_q,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM users LIMIT 100",
        st.list,
    );
    try std.testing.expectEqualStrings(
        "UPDATE users SET name=$1,email=$2 WHERE id = $3",
        st.update_pg,
    );
    try std.testing.expectEqualStrings(
        "UPDATE users SET name=?,email=? WHERE id = ?",
        st.update_q,
    );
    try std.testing.expectEqualStrings(
        "DELETE FROM users WHERE id = $1",
        st.delete_pg,
    );
    try std.testing.expectEqualStrings(
        "DELETE FROM users WHERE id = ?",
        st.delete_q,
    );
}
