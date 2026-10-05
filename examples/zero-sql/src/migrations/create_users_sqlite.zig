const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1700000002;

pub fn create_users_sqlite_run(c: *Context) anyerror!void {
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (
        \\   id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\   name VARCHAR(255) NOT NULL,
        \\   email VARCHAR(255) NOT NULL
        \\ )
    ;
    _ = try c.SQL.exec(c, query, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .relational,
    .dialect = .sqlite,
    .run = create_users_sqlite_run,
};
