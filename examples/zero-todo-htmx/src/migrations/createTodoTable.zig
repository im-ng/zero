const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1760947008;

pub fn addTodoTable(c: *Context) anyerror!void {
    const addTodoTableQuery =
        \\    CREATE TABLE IF NOT EXISTS todos (
        \\    id SERIAL PRIMARY KEY, 
        \\    task TEXT NOT NULL, 
        \\    description TEXT NOT NULL, 
        \\    is_done bool NOT NULL DEFAULT false, 
        \\    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\);
    ;
    _ = try c.SQL.exec(addTodoTableQuery, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .run = addTodoTable,
};
