const zero = @import("zero");
const migrate = zero.migrate;
const Context = zero.Context;

pub const migrationNumber: i64 = 1760953394;

pub fn addTodoEntries(c: *Context) !void {
    const addTodoTableQuery =
        \\ INSERT INTO todos(task, description) values ('task 0', 'Gettings started!!');
    ;
    _ = try c.SQL.exec(addTodoTableQuery, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .run = addTodoEntries,
};
