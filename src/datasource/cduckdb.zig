const std = @import("std");

/// Minimal C bindings for the DuckDB C API (amalgamated `duckdb.h`). Declared
/// explicitly (rather than via `@cImport`) to keep the build fast and avoid
/// translate-c churn. The shared library is linked from `libs/libduckdb.so`
/// (see `build.zig`).
pub const idx_t = u64;
pub const duckdb_state = c_int;
pub const duckdb_type = c_int;

/// `typedef struct _duckdb_database { ... } *duckdb_database;` — a pointer type.
pub const duckdb_database = ?*anyopaque;
/// `typedef struct _duckdb_connection { ... } *duckdb_connection;`
pub const duckdb_connection = ?*anyopaque;
/// `duckdb_result` is a struct passed by value.
pub const duckdb_result = extern struct {
    deprecated_column_count: idx_t,
    deprecated_row_count: idx_t,
    deprecated_rows_changed: idx_t,
    deprecated_columns: ?*anyopaque,
    deprecated_error_message: ?[*:0]u8,
    internal_data: ?*anyopaque,
};

pub const duckdb_string = extern struct {
    data: ?[*:0]u8,
    size: idx_t,
};

pub const DUCKDB_TYPE_VARCHAR: duckdb_type = 17;

pub extern fn duckdb_open(path: ?[*:0]const u8, db: *duckdb_database) duckdb_state;
pub extern fn duckdb_close(db: *duckdb_database) void;
pub extern fn duckdb_connect(db: duckdb_database, conn: *duckdb_connection) duckdb_state;
pub extern fn duckdb_disconnect(conn: *duckdb_connection) void;
pub extern fn duckdb_query(conn: duckdb_connection, query: [*:0]const u8, out_result: *duckdb_result) duckdb_state;
pub extern fn duckdb_destroy_result(result: *duckdb_result) void;
pub extern fn duckdb_column_count(result: *duckdb_result) idx_t;
pub extern fn duckdb_row_count(result: *duckdb_result) idx_t;
pub extern fn duckdb_column_name(result: *duckdb_result, col: idx_t) [*:0]const u8;
pub extern fn duckdb_column_type(result: *duckdb_result, col: idx_t) duckdb_type;
pub extern fn duckdb_value_int64(result: *duckdb_result, col: idx_t, row: idx_t) i64;
pub extern fn duckdb_value_double(result: *duckdb_result, col: idx_t, row: idx_t) f64;
pub extern fn duckdb_value_boolean(result: *duckdb_result, col: idx_t, row: idx_t) bool;
pub extern fn duckdb_value_string(result: *duckdb_result, col: idx_t, row: idx_t) duckdb_string;
pub extern fn duckdb_value_is_null(result: *duckdb_result, col: idx_t, row: idx_t) bool;
pub extern fn duckdb_free(ptr: ?*anyopaque) void;

/// `duckdb_prepared_statement` is a pointer type (opaque handle).
pub const duckdb_prepared_statement = ?*anyopaque;

pub extern fn duckdb_prepare(conn: duckdb_connection, query: [*:0]const u8, out_stmt: *duckdb_prepared_statement) duckdb_state;
pub extern fn duckdb_destroy_prepare(stmt: *duckdb_prepared_statement) void;
pub extern fn duckdb_execute_prepared(stmt: duckdb_prepared_statement, out_result: *duckdb_result) duckdb_state;
pub extern fn duckdb_bind_int64(stmt: duckdb_prepared_statement, idx: idx_t, val: i64) duckdb_state;
pub extern fn duckdb_bind_double(stmt: duckdb_prepared_statement, idx: idx_t, val: f64) duckdb_state;
pub extern fn duckdb_bind_boolean(stmt: duckdb_prepared_statement, idx: idx_t, val: bool) duckdb_state;
pub extern fn duckdb_bind_varchar(stmt: duckdb_prepared_statement, idx: idx_t, val: [*:0]const u8) duckdb_state;
pub extern fn duckdb_bind_null(stmt: duckdb_prepared_statement, idx: idx_t) duckdb_state;

/// Allocate a null-terminated C string copy of `s` (caller frees with `allocator`).
pub fn toCStr(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return try allocator.dupeZ(u8, s);
}
