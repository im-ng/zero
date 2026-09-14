const zero = @import("zero");
const migrate = zero.migrate;
const Context = zero.Context;

pub const migrationNumber: i64 = 1760953394;

pub fn addTodoEntries(ctx: *Context) !void {
    const addTodoTableQuery =
        \\ INSERT INTO todos(task, description) values ('task 0', 'Gettings started!!');
    ;
    _ = try ctx.SQL.exec(ctx, addTodoTableQuery, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .run = addTodoEntries,
};
