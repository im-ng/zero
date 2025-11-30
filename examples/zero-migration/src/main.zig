const std = @import("std");
const zero = @import("zero");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const App = zero.App;
const Context = zero.Context;
const migrate = zero.migrate;
const container = zero.container;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

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

    const key = try utils.toStringFromInt(a.container.allocator, "{d}", addTodoMigration.migrationNumber);

    try a.addMigration(key, addTodoMigration);

    // 2. add todo entries
    const todoEntries = &migrate{
        .migrationNumber = 1760953394,
        .run = addTodoEntries,
    };

    const key2 = try utils.toStringFromInt(a.container.allocator, "{d}", todoEntries.migrationNumber);

    try a.addMigration(key2, todoEntries);
}

pub fn addTodoTable(c: *Context) anyerror!void {
    const addTodoTableQuery =
        \\ CREATE TABLE IF NOT EXISTS todos (id SERIAL PRIMARY KEY, task TEXT NOT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP );
    ;
    _ = try c.SQL.exec(addTodoTableQuery, .{});
}

pub fn addTodoEntries(c: *Context) !void {
    const addTodoTableQuery =
        \\ INSERT INTO todos(task) values ('add migrations');
        \\ INSERT INTO todos(task) values ('verify migrations');
    ;
    _ = try c.SQL.exec(addTodoTableQuery, .{});
}
