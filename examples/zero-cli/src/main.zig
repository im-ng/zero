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
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    // CLI mode: wires up config, logging, container/datasources and migrations
    // but starts NO HTTP or metrics server. Dispatch commands with runCmd.
    const app = try App.newCmd(allocator, init.environ_map);

    // In-process OLAP SQL engine for the demo (no external service required).
    // A file path is used (not ":memory:") so `seed` and `list` share state
    // across separate CLI invocations. Swap for addSQL / addSQLite / addNoSQL
    // to drive other backends from the CLI.
    // try app.addDuckDB(app.config.get("DUCKDB_PATH"));

    // Register subcommands. Flags passed after the command are parsed into
    // ctx.params (e.g. `--name John` -> ctx.Param("name") == "John").
    try app.SubCommand("seed", seed, .{ .description = "create + populate the demo table" });
    try app.SubCommand("list", list, .{ .description = "list rows from the demo table" });
    try app.SubCommand("greet", greet, .{ .description = "print a greeting (pass --name <who>)" });

    try app.runCmd(init.minimal.args);
}

fn ensureSchema(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS cli_users (id INTEGER, name VARCHAR)", .{});
}

pub fn seed(ctx: *Context) !void {
    try ensureSchema(ctx);
    _ = try ctx.SQL.exec(ctx, "INSERT INTO cli_users VALUES (1, 'alice'), (2, 'bob')", .{});
    ctx.println("seeded cli_users with 2 rows", .{});
}

pub fn list(ctx: *Context) !void {
    try ensureSchema(ctx);
    const users = try ctx.SQL.queryRows(ctx, User, "SELECT id, name FROM cli_users ORDER BY id", .{});
    defer {
        for (users) |u| ctx.allocator.free(u.name);
        ctx.allocator.free(users);
    }
    if (users.len == 0) {
        ctx.println("(no rows)", .{});
        return;
    }
    ctx.println("{s:<4} {s}", .{ "ID", "NAME" });
    for (users) |u| {
        ctx.println("{d:<4} {s}", .{ u.id, u.name });
    }
}

pub fn greet(ctx: *Context) !void {
    const name = ctx.Param("name") orelse "world";
    ctx.println("hello, {s}!", .{name});
}
