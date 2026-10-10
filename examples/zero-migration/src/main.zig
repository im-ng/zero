const std = @import("std");
const zero = @import("zero");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const App = zero.App;
const Context = zero.Context;
const migrate = zero.migrate;
const container = zero.container;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    try prepareMigrations(app);

    try app.runMigrations();

    try app.run();
}

fn prepareMigrations(a: *App) !void {
    // 1. add todo table
    const addTodoMigration = &migrate{
        .migrationNumber = 1760947008,
        .run = addTodoTable,
    };

    const key = try std.fmt.allocPrint(a.container.allocator, "{d}", .{addTodoMigration.migrationNumber});

    try a.addMigration(key, addTodoMigration);
    a.container.allocator.free(key);

    // 2. add todo entries
    const todoEntries = &migrate{
        .migrationNumber = 1760953394,
        .run = addTodoEntries,
    };

    const key2 = try std.fmt.allocPrint(a.container.allocator, "{d}", .{todoEntries.migrationNumber});

    try a.addMigration(key2, todoEntries);
    a.container.allocator.free(key2);
}

pub fn addTodoTable(c: *Context) anyerror!void {
    const addTodoTableQuery =
        \\ CREATE TABLE IF NOT EXISTS todos (id SERIAL PRIMARY KEY, task TEXT NOT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP );
    ;
    _ = try c.SQL.exec(c, addTodoTableQuery, .{});
}

pub fn addTodoEntries(c: *Context) !void {
    const addTodoTableQuery =
        \\ INSERT INTO todos(task) values ('add migrations');
        \\ INSERT INTO todos(task) values ('verify migrations');
    ;
    _ = try c.SQL.exec(c, addTodoTableQuery, .{});
}
