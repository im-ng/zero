const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const Memory = zero.memory;
const CPU = zero.cpu;
const Process = zero.process;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var ix: usize = 0;
    std.log.err("=== Stack Trace ==============", .{});
    while (it.next()) |frame| : (ix += 1) {
        std.log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }
}

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator);

    try app.get("/", index);
    try app.get("/sqlite/init", sqliteInit);
    try app.post("/sqlite/users", createUser);
    try app.get("/sqlite/users", listUsers);
    try app.get("/sqlite/users/:id", getUser);
    try app.put("/sqlite/users/:id", updateUser);
    try app.delete("/sqlite/users/:id", deleteUser);
    try app.get("/memory", memoryUsage);

    try app.run();
}

pub fn memoryUsage(ctx: *Context) !void {
    const c = try CPU.info(ctx);
    ctx.any(c);
    ctx.any(CPU.usage());
    ctx.any(CPU.percentageUsed());
    const path = try utils.combine(ctx.allocator, "/proc/{d}/status", .{std.c.getpid()});
    _ = try Process.usage(ctx.allocator, path);
    try ctx.json(c);
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ SQLite Demo - Zero Framework
        \\ ===========================
        \\
        \\ CRUD Endpoints:
        \\ POST   /sqlite/users         - Create user
        \\ GET    /sqlite/users         - List all users
        \\ GET    /sqlite/users/{id}    - Get user by ID
        \\ PUT    /sqlite/users/{id}    - Update user
        \\ DELETE /sqlite/users/{id}    - Delete user
        \\ GET    /sqlite/init          - Initialize database
        \\ GET    /memory               - System info
    ;
}

pub fn sqliteInit(ctx: *Context) !void {
    ctx.response.setStatus(.ok);

    try ctx.SQLite.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT NOT NULL
        \\)
    , .{});

    try ctx.json(.{ .message = "Database initialized with users table" });
}

pub fn createUser(ctx: *Context) !void {
    const body = ctx.request.body() orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Request body required" });
        return;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Invalid JSON", .details = @errorName(err) });
        return;
    };
    defer parsed.deinit();

    const name = parsed.value.object.get("name") orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "name field required" });
        return;
    };

    const email = parsed.value.object.get("email") orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "email field required" });
        return;
    };

    const name_str = switch (name) {
        .string => |s| s,
        else => {
            ctx.response.setStatus(.bad_request);
            try ctx.json(.{ .err = "name must be a string" });
            return;
        },
    };

    const email_str = switch (email) {
        .string => |s| s,
        else => {
            ctx.response.setStatus(.bad_request);
            try ctx.json(.{ .err = "email must be a string" });
            return;
        },
    };

    try ctx.SQLite.exec(
        "INSERT INTO users (name, email) VALUES (?, ?)",
        .{ name_str, email_str },
    );

    const id = ctx.SQLite.lastInsertRowID();

    ctx.response.setStatus(.created);
    try ctx.json(.{ .message = "User created", .id = id, .name = name_str, .email = email_str });
}

pub fn listUsers(ctx: *Context) !void {
    const users = try ctx.SQLite.queryRowsContext(User, ctx.allocator, "SELECT id, name, email FROM users", .{});

    ctx.response.setStatus(.ok);
    try ctx.json(.{ .count = users.len, .users = users });
}

pub fn getUser(ctx: *Context) !void {
    const id_str = ctx.param("id");
    const id = std.fmt.parseInt(i64, id_str, 10) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Invalid ID", .details = @errorName(err) });
        return;
    };

    const user = try ctx.SQLite.queryRowContext(User, ctx.allocator, "SELECT id, name, email FROM users WHERE id = ?", .{id});

    if (user) |u| {
        ctx.response.setStatus(.ok);
        try ctx.json(u);
    } else {
        ctx.response.setStatus(.not_found);
        try ctx.json(.{ .err = "User not found", .id = id });
    }
}

pub fn updateUser(ctx: *Context) !void {
    const id_str = ctx.param("id");
    const id = std.fmt.parseInt(i64, id_str, 10) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Invalid ID", .details = @errorName(err) });
        return;
    };

    const body = ctx.request.body() orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Request body required" });
        return;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Invalid JSON", .details = @errorName(err) });
        return;
    };
    defer parsed.deinit();

    const name = parsed.value.object.get("name");
    const email = parsed.value.object.get("email");

    if (name == null and email == null) {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "At least one field (name or email) required" });
        return;
    }

    const name_str = if (name) |n| switch (n) {
        .string => |s| s,
        else => blk: {
            ctx.response.setStatus(.bad_request);
            try ctx.json(.{ .err = "name must be a string" });
            break :blk null;
        },
    } else null;

    const email_str = if (email) |e| switch (e) {
        .string => |s| s,
        else => blk: {
            ctx.response.setStatus(.bad_request);
            try ctx.json(.{ .err = "email must be a string" });
            break :blk null;
        },
    } else null;

    if (name_str) |n| {
        if (email_str) |e| {
            try ctx.SQLite.exec(
                "UPDATE users SET name = ?, email = ? WHERE id = ?",
                .{ n, e, id },
            );
        } else {
            try ctx.SQLite.exec(
                "UPDATE users SET name = ? WHERE id = ?",
                .{ n, id },
            );
        }
    } else if (email_str) |e| {
        try ctx.SQLite.exec(
            "UPDATE users SET email = ? WHERE id = ?",
            .{ e, id },
        );
    }

    const affected = ctx.SQLite.rowsAffected();
    if (affected == 0) {
        ctx.response.setStatus(.not_found);
        try ctx.json(.{ .err = "User not found", .id = id });
    } else {
        ctx.response.setStatus(.ok);
        try ctx.json(.{ .message = "User updated", .id = id, .affected = affected });
    }
}

pub fn deleteUser(ctx: *Context) !void {
    const id_str = ctx.param("id");
    const id = std.fmt.parseInt(i64, id_str, 10) catch |err| {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .err = "Invalid ID", .details = @errorName(err) });
        return;
    };

    try ctx.SQLite.exec(
        "DELETE FROM users WHERE id = ?",
        .{id},
    );

    const affected = ctx.SQLite.rowsAffected();
    if (affected == 0) {
        ctx.response.setStatus(.not_found);
        try ctx.json(.{ .err = "User not found", .id = id });
    } else {
        ctx.response.setStatus(.ok);
        try ctx.json(.{ .message = "User deleted", .id = id, .affected = affected });
    }
}
