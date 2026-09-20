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

const NewUser = struct {
    name: []const u8,
    email: []const u8,
};

const NextId = struct { id: i64 };

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    // In-process OLAP SQL engine. No external service required.
    // Pass a file path instead of ":memory:" for a persistent database.
    try app.addDuckDB(":memory:");

    try app.get("/", index);
    try app.get("/users", listUsers);
    try app.post("/users", createUser);
    try app.get("/users/:id", getUser);
    try app.put("/users/:id", updateUser);
    try app.delete("/users/:id", deleteUser);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ DuckDB (in-process OLAP SQL) CRUD demo.
        \\ Routes (table = "users"):
        \\   GET    /users            list users
        \\   POST   /users            create a user (JSON {name,email})
        \\   GET    /users/:id        get a user by id
        \\   PUT    /users/:id        update a user (JSON {name,email})
        \\   DELETE /users/:id        delete a user by id
        \\
        \\ Database is in-memory by default; pass a file path to addDuckDB() to persist.
    ;
}

fn ensureSchema(ctx: *Context) !void {
    _ = try ctx.SQL.exec(
        ctx,
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name VARCHAR, email VARCHAR)",
        .{},
    );
}

fn parseId(ctx: *Context) ?i64 {
    const raw = ctx.request.params.get("id") orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn badRequest(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.bad_request);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

pub fn listUsers(ctx: *Context) !void {
    try ensureSchema(ctx);
    const users = try ctx.SQL.queryRows(ctx, User, "SELECT id, name, email FROM users ORDER BY id", .{});
    defer {
        for (users) |u| {
            ctx.allocator.free(u.name);
            ctx.allocator.free(u.email);
        }
        ctx.allocator.free(users);
    }
    try ctx.response.json(.{ .data = users }, .{});
}

pub fn createUser(ctx: *Context) !void {
    const body = (ctx.bind(NewUser) catch {
        badRequest(ctx, "invalid JSON body; expected {\"name\":...,\"email\":...}");
        return;
    }) orelse {
        badRequest(ctx, "empty request body");
        return;
    };
    try ensureSchema(ctx);

    const next = blk: {
        const row = (try ctx.SQL.queryRow(ctx, NextId, "SELECT COALESCE(MAX(id),0)+1 AS id FROM users", .{})) orelse NextId{ .id = 1 };
        break :blk row.id;
    };

    _ = try ctx.SQL.exec(ctx, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", .{ next, body.name, body.email });
    try ctx.response.json(.{ .id = next, .status = "created" }, .{});
}

pub fn getUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse {
        badRequest(ctx, "invalid :id");
        return;
    };
    try ensureSchema(ctx);
    const user = try ctx.SQL.queryRow(ctx, User, "SELECT id, name, email FROM users WHERE id = ?", .{id});
    if (user) |u| {
        defer {
            ctx.allocator.free(u.name);
            ctx.allocator.free(u.email);
        }
        try ctx.response.json(u, .{});
    } else {
        ctx.response.setStatus(.not_found);
        try ctx.response.json(.{ .message = "not found", .id = id }, .{});
    }
}

pub fn updateUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse {
        badRequest(ctx, "invalid :id");
        return;
    };
    const body = (ctx.bind(NewUser) catch {
        badRequest(ctx, "invalid JSON body; expected {\"name\":...,\"email\":...}");
        return;
    }) orelse {
        badRequest(ctx, "empty request body");
        return;
    };
    try ensureSchema(ctx);

    _ = try ctx.SQL.exec(ctx, "UPDATE users SET name = ?, email = ? WHERE id = ?", .{ body.name, body.email, id });
    try ctx.response.json(.{ .id = id, .status = "updated" }, .{});
}

pub fn deleteUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse {
        badRequest(ctx, "invalid :id");
        return;
    };
    try ensureSchema(ctx);
    _ = try ctx.SQL.exec(ctx, "DELETE FROM users WHERE id = ?", .{id});
    try ctx.response.json(.{ .id = id, .status = "deleted" }, .{});
}
