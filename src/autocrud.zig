const std = @import("std");
const root = @import("zero.zig");

const App = root.App;
const Context = root.Context;

/// Comptime identifier quoting for trusted schema names used inside the
/// generated CRUD queries. `dq` wraps in double-quotes (Postgres/SQLite/DuckDB
/// style), `bq` in backticks (MySQL/ClickHouse style). Untrusted identifiers
/// should go through `datasourceInterface.quoteIdentifier` at runtime instead.
fn dq(name: []const u8) []const u8 {
    return "\"" ++ name ++ "\"";
}

fn bq(name: []const u8) []const u8 {
    return "`" ++ name ++ "`";
}

/// Options for `addRestHandlers`. `resource` is the URL segment (e.g. `"users"`
/// registers `/users`, `/users/:id`, …). `table` defaults to `resource`
/// primary key is `id` unless `id_field` says otherwise.
pub const AutoCrudOptions = struct {
    resource: []const u8,
    table: []const u8 = "",
    id_field: []const u8 = "id",
};

fn tupleTypes(comptime T: type, comptime skip_id: ?usize) []const type {
    const fields = .{ .names = @typeInfo(T).@"struct".field_names, .types = @typeInfo(T).@"struct".field_types, .attrs = @typeInfo(T).@"struct".field_attrs };
    comptime var arr: [fields.names.len]type = undefined;
    comptime var k: usize = 0;
    inline for (fields.names, fields.types, fields.attrs, 0..) |_, f_type, _, i| {
        if (skip_id) |s| if (i == s) continue;
        arr[k] = f_type;
        k += 1;
    }
    if (skip_id) |s| {
        arr[k] = fields.types[s];
    }
    return &arr;
}

fn toTuple(comptime T: type, obj: T, comptime skip_id: ?usize) @Tuple(tupleTypes(T, skip_id)) {
    var r: @Tuple(tupleTypes(T, skip_id)) = undefined;
    comptime var dst: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, @typeInfo(T).@"struct".field_attrs, 0..) |f_name, _, _, i| {
        if (skip_id) |s| if (i == s) continue;
        r[dst] = @field(obj, f_name);
        dst += 1;
    }
    if (skip_id) |s| {
        r[dst] = @field(obj, @typeInfo(T).@"struct".field_names[s]);
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
    const fields = .{ .names = @typeInfo(T).@"struct".field_names, .types = @typeInfo(T).@"struct".field_types, .attrs = @typeInfo(T).@"struct".field_attrs };
    const n = fields.names.len;

    comptime var c: []const u8 = "";
    inline for (fields.names, fields.types, fields.attrs, 0..) |f_name, _, _, i| {
        if (i > 0) {
            c = c ++ ",";
        }
        c = c ++ f_name;
    }

    comptime var pgph: []const u8 = "";
    inline for (0..n) |i| {
        if (i > 0) {
            pgph = pgph ++ ",";
        }
        pgph = pgph ++ std.fmt.comptimePrint("${d}", .{i + 1});
    }

    comptime var qph: []const u8 = "";
    inline for (0..n) |i| {
        if (i > 0) {
            qph = qph ++ ",";
        }
        qph = qph ++ "?";
    }

    comptime var set_pg: []const u8 = "";
    comptime var set_q: []const u8 = "";
    var p: usize = 0;
    inline for (fields.names, fields.types, fields.attrs, 0..) |f_name, _, _, i| {
        if (i == id_idx) continue;
        p += 1;
        if (p > 1) {
            set_pg = set_pg ++ ",";
            set_q = set_q ++ ",";
        }
        set_pg = set_pg ++ f_name ++ std.fmt.comptimePrint("=${d}", .{p});
        set_q = set_q ++ f_name ++ "=?";
    }

    const non_id = n - 1;
    return .{
        .insert_pg = "INSERT INTO " ++ dq(table) ++ " (" ++ c ++ ") VALUES (" ++ pgph ++ ")",
        .insert_q = "INSERT INTO " ++ bq(table) ++ " (" ++ c ++ ") VALUES (" ++ qph ++ ")",
        .get_pg = "SELECT " ++ c ++ " FROM " ++ dq(table) ++ " WHERE " ++ dq(id_field) ++ " = $1",
        .get_q = "SELECT " ++ c ++ " FROM " ++ bq(table) ++ " WHERE " ++ bq(id_field) ++ " = ?",
        .list = "SELECT " ++ c ++ " FROM " ++ table ++ " LIMIT 100",
        .update_pg = "UPDATE " ++ dq(table) ++ " SET " ++ set_pg ++ " WHERE " ++ dq(id_field) ++ " = $" ++ std.fmt.comptimePrint("{d}", .{non_id + 1}),
        .update_q = "UPDATE " ++ bq(table) ++ " SET " ++ set_q ++ " WHERE " ++ bq(id_field) ++ " = ?",
        .delete_pg = "DELETE FROM " ++ dq(table) ++ " WHERE " ++ dq(id_field) ++ " = $1",
        .delete_q = "DELETE FROM " ++ bq(table) ++ " WHERE " ++ bq(id_field) ++ " = ?",
    };
}

// Postgres/DuckGres use `$N` placeholders; every other dialect uses `?`.
// The `ctx.SQL` interface routes to the right backend and applies the circuit
// breaker + datasource metrics, which the old 7-way dialect switch bypassed
fn useDollarPlaceholders(ctx: *Context) bool {
    return ctx.SQL.dialect == .postgres or ctx.SQL.dialect == .duckgres;
}

fn listHandler(comptime T: type, comptime st: Stmts) *const fn (*Context) anyerror!void {
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const rows = try ctx.SQL.queryRows(ctx, T, st.list, .{});
            try ctx.json(rows);
        }
    };
    return &impl.call;
}

fn getHandler(comptime T: type, comptime st: Stmts, comptime id_idx: usize) *const fn (*Context) anyerror!void {
    const IdType = @typeInfo(T).@"struct".field_types[id_idx];
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const raw = ctx.param("id");
            const idv = parseId(IdType, raw) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid id" });
                return;
            };
            const stmt = if (useDollarPlaceholders(ctx)) st.get_pg else st.get_q;
            const row = try ctx.SQL.queryRow(ctx, T, stmt, .{idv});
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
            const stmt = if (useDollarPlaceholders(ctx)) st.insert_pg else st.insert_q;
            _ = try ctx.SQL.exec(ctx, stmt, args);
            try ctx.json(o);
            ctx.response.setStatus(.created);
        }
    };
    return &impl.call;
}

fn updateHandler(comptime T: type, comptime st: Stmts, comptime id_idx: usize) *const fn (*Context) anyerror!void {
    const IdType = @typeInfo(T).@"struct".field_types[id_idx];
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
            const stmt = if (useDollarPlaceholders(ctx)) st.update_pg else st.update_q;
            const updated = (try ctx.SQL.exec(ctx, stmt, args)) > 0;
            if (!updated) {
                ctx.response.setStatus(.not_found);
                try ctx.json(.{ .err = "not found" });
                return;
            }
            const get_stmt = if (useDollarPlaceholders(ctx)) st.get_pg else st.get_q;
            const row = try ctx.SQL.queryRow(ctx, T, get_stmt, .{idv});
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
    const IdType = @typeInfo(T).@"struct".field_types[id_idx];
    const impl = struct {
        fn call(ctx: *Context) anyerror!void {
            const raw = ctx.param("id");
            const idv = parseId(IdType, raw) catch {
                ctx.response.setStatus(.bad_request);
                try ctx.json(.{ .err = "invalid id" });
                return;
            };
            const stmt = if (useDollarPlaceholders(ctx)) st.delete_pg else st.delete_q;
            _ = try ctx.SQL.exec(ctx, stmt, .{idv});
            const affected = ctx.SQL.rowsAffected();
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
/// the configured SQL datasource (Postgres, SQLite, DuckDB, DuckGres, or MySQL —
/// all are generated and dispatched at runtime on `ctx.SQL.dialect`).
pub fn addRestHandlers(self: *App, comptime T: type, comptime opts: AutoCrudOptions) !void {
    const table = if (opts.table.len > 0) opts.table else opts.resource;
    const id_field = opts.id_field;

    const fields = .{ .names = @typeInfo(T).@"struct".field_names, .types = @typeInfo(T).@"struct".field_types, .attrs = @typeInfo(T).@"struct".field_attrs };
    comptime var id_idx: ?usize = null;
    inline for (fields.names, fields.types, fields.attrs, 0..) |f_name, _, _, i| {
        if (comptime std.mem.eql(u8, f_name, id_field)) id_idx = i;
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

test "AutoCrud listHandler routes through ctx.SQL interface (argon T19)" {
    // Before the fix the CRUD handlers switched over every dialect and called the
    // concrete backend directly, bypassing `ctx.SQL`'s circuit breaker + metrics.
    // Now `listHandler` goes through `ctx.SQL.queryRows`, so the type-erased
    // interface (and its breaker) is exercised end-to-end.
    const t = root.httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var mb: root.datasourceInterface.MockBackend = .{};
    const breaker = root.circuit_breaker.CircuitBreaker.init(root.circuit_breaker.CircuitBreakerConfig{});
    const ds = root.datasourceInterface.Interface.init(&mb, .mock, breaker, null);

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;
    ctx.SQL = ds;

    const st = comptime buildStmts(Sample, "users", "id", 0);
    try listHandler(Sample, st)(&ctx);

    try std.testing.expect(mb.query_rows_calls > 0);
    // `query_rows_calls` only increments inside the type-erased `MockBackend`
    // reached through `ctx.SQL.queryRows`, proving the handler routed through the
    // interface (which now also consults the circuit breaker) instead of a dialect
    // switch that bypassed it.
}

// ===================== Tests =====================

test "AutoCrud generates dialect-correct SQL" {
    const st = comptime buildStmts(Sample, "users", "id", 0);
    try std.testing.expectEqualStrings(
        "INSERT INTO \"users\" (id,name,email) VALUES ($1,$2,$3)",
        st.insert_pg,
    );
    try std.testing.expectEqualStrings(
        "INSERT INTO `users` (id,name,email) VALUES (?,?,?)",
        st.insert_q,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM \"users\" WHERE \"id\" = $1",
        st.get_pg,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM `users` WHERE `id` = ?",
        st.get_q,
    );
    try std.testing.expectEqualStrings(
        "SELECT id,name,email FROM users LIMIT 100",
        st.list,
    );
    try std.testing.expectEqualStrings(
        "UPDATE \"users\" SET name=$1,email=$2 WHERE \"id\" = $3",
        st.update_pg,
    );
    try std.testing.expectEqualStrings(
        "UPDATE `users` SET name=?,email=? WHERE `id` = ?",
        st.update_q,
    );
    try std.testing.expectEqualStrings(
        "DELETE FROM \"users\" WHERE \"id\" = $1",
        st.delete_pg,
    );
    try std.testing.expectEqualStrings(
        "DELETE FROM `users` WHERE `id` = ?",
        st.delete_q,
    );
}
