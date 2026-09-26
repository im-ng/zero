const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    // propogate error up
    app.onStartup(initDb);

    try app.get("/", index);

    // One line wires up list / get / create / update / delete for `User`, routed
    // through ctx.SQL (dialect=duckgres) — the same relational surface as the
    // in-process DuckDB / Postgres backends.
    try app.addRestHandlers(User, .{ .resource = "users" });

    try app.run();
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ DuckGres Demo - Zero Framework
        \\ ==========================
        \\
        \\ A wired DuckDB client talking the Postgres wire protocol to a DuckDB
        \\ PG-wire front-end (DB_DIALECT=duckgres). CRUD is served via ctx.SQL.
        \\
        \\ GET    /users                - List users
        \\ GET    /users/:id            - Get user by ID
        \\ POST   /users                - Create user (body: {"id":N,"name":..,"email":..})
        \\ PUT    /users/:id            - Update user
        \\ DELETE /users/:id            - Delete user
    ;
}

pub fn initDb(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx,
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    email TEXT NOT NULL
        \\)
    , .{});
}
