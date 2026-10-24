const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1700000003;

pub fn create_users_duckdb_run(c: *Context) anyerror!void {
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (
        \\   id INTEGER PRIMARY KEY,
        \\   name VARCHAR NOT NULL,
        \\   email VARCHAR NOT NULL
        \\ )
    ;
    _ = try c.SQL.exec(c, query, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .relational,
    .dialect = .duckdb,
    .run = create_users_duckdb_run,
};
