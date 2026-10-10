const std = @import("std");
const zero = @import("zero");
const migrations = @import("migrations/all.zig");

const App = zero.App;
const Context = zero.Context;

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

    // Run the per-dialect migrations. Only the migration whose `.dialect` matches
    // the active DB_DIALECT is applied; the rest are skipped.
    try migrations.all(app);
    try app.runMigrations();

    try app.get("/", index);
    try app.get("/users", listUsers);
    try app.post("/users", createUser);
    try app.get("/users/:id", getUser);
    try app.put("/users/:id", updateUser);
    try app.delete("/users/:id", deleteUser);

    try app.run();

    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ zero-sql: multi-dialect SQL pack (Postgres / SQLite / DuckDB / ClickHouse).
        \\ One backend binds to ctx.SQL, chosen by DB_DIALECT in configs/.env.
        \\ Each dialect's `users` migration ships under src/migrations/ and the
        \\ runner applies only the active dialect's version.
        \\
        \\ Routes (table = "users"):
        \\   GET    /users            list users
        \\   POST   /users            create a user (JSON {name,email})
        \\   GET    /users/:id        get a user by id
        \\   PUT    /users/:id        update a user (JSON {name,email})
        \\   DELETE /users/:id        delete a user by id
        \\
        \\ With no DB_DIALECT set the routes return 501 (not configured).
    ;
}

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(.{ .message = "no SQL datasource configured (set DB_DIALECT)" }, .{}) catch {};
}

/// True when any relational backend is wired (postgres/sqlite/duckdb/clickhouse/
/// duckgres). `ctx.SQL` is a non-null struct, so we must inspect the container's
/// backend pointers rather than comparing it to `null`.
fn sqlConfigured(ctx: *Context) bool {
    const c = ctx.container;
    return c.SQL != null or c.SQLite != null or c.DuckDB != null or
        c.ClickHouse != null or c.DuckGres != null;
}

fn parseId(ctx: *Context) ?i64 {
    const raw = ctx.request.?.params.get("id") orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn badRequest(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.bad_request);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

pub fn listUsers(ctx: *Context) !void {
    if (!sqlConfigured(ctx)) {
        notConfigured(ctx);
        return;
    }
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
    if (!sqlConfigured(ctx)) {
        notConfigured(ctx);
        return;
    }
    const body = (ctx.bind(NewUser) catch {
        badRequest(ctx, "invalid JSON body; expected {\"name\":...,\"email\":...}");
        return;
    }) orelse {
        badRequest(ctx, "empty request body");
        return;
    };

    // Derive the next id in-app; works uniformly across SQLite/DuckDB/Postgres
    // (SERIAL/AUTOINCREMENT ignored) and ClickHouse (no AUTO_INCREMENT).
    const next = blk: {
        const row = (try ctx.SQL.queryRow(ctx, NextId, "SELECT COALESCE(MAX(id),0)+1 AS id FROM users", .{})) orelse NextId{ .id = 1 };
        break :blk row.id;
    };

    _ = try ctx.SQL.exec(ctx, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", .{ next, body.name, body.email });
    try ctx.response.json(.{ .id = next, .status = "created" }, .{});
}

pub fn getUser(ctx: *Context) !void {
    if (!sqlConfigured(ctx)) {
        notConfigured(ctx);
        return;
    }
    const id = parseId(ctx) orelse {
        badRequest(ctx, "invalid :id");
        return;
    };
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
    if (!sqlConfigured(ctx)) {
        notConfigured(ctx);
        return;
    }
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

    _ = try ctx.SQL.exec(ctx, "UPDATE users SET name = ?, email = ? WHERE id = ?", .{ body.name, body.email, id });
    try ctx.response.json(.{ .id = id, .status = "updated" }, .{});
}

pub fn deleteUser(ctx: *Context) !void {
    if (!sqlConfigured(ctx)) {
        notConfigured(ctx);
        return;
    }
    const id = parseId(ctx) orelse {
        badRequest(ctx, "invalid :id");
        return;
    };
    _ = try ctx.SQL.exec(ctx, "DELETE FROM users WHERE id = ?", .{id});
    try ctx.response.json(.{ .id = id, .status = "deleted" }, .{});
}
