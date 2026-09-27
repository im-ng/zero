const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1790401496;

pub fn createUser_run(c: *Context) anyerror!void {
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name VARCHAR, email VARCHAR);
    ;
    _ = try c.SQL.exec(c, query, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .run = createUser_run,
};
