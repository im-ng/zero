const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const migrate = zero.migrate;
const utils = zero.utils;

// Generated from proto/crud.proto by `zig build gen-proto`.
const crud = @import("proto/crud.pb.zig");

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

// Plain struct the Postgres mapper fills. `email` is nullable to match the
// optional protobuf field and the nullable column.
const User = struct {
    id: i64,
    name: []const u8,
    email: ?[]const u8,
};

// Migration: (re)create the isolated `proto_users` table.
fn createProtoUsersTable(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx,
        \\DROP TABLE IF EXISTS proto_users;
        \\CREATE TABLE proto_users (
        \\    id BIGSERIAL PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    email TEXT
        \\)
    , .{});
}

const createProtoUsersMigration = &migrate{
    .migrationNumber = 1760947300,
    .run = createProtoUsersTable,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);

    // Run the migration explicitly (app.run() does not auto-run migrations;
    // re-runs are skipped via the zero_migrations bookkeeping table).
    const key = try utils.toStringFromInt(app.container.allocator, "{d}", createProtoUsersMigration.migrationNumber);
    try app.addMigration(key, createProtoUsersMigration);
    try app.runMigrations();

    // Postgres-backed CRUD over protobuf (Content-Type: application/x-protobuf).
    try app.post("/users", createUser);
    try app.get("/users", listUsers);
    try app.get("/users/:id", getUser);
    try app.put("/users/:id", updateUser);
    try app.delete("/users/:id", deleteUser);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\Postgres CRUD over protobuf - Zero Framework
        \\=============================================
        \\
        \\ All endpoints exchange `application/x-protobuf` bodies (see
        \\ proto/crud.proto). `id` is a path parameter for single-resource ops.
        \\
        \\ POST   /users            - Create user  (CreateUserRequest  -> UserResponse)
        \\ GET    /users            - List users   (empty body         -> UserList)
        \\ GET    /users/:id        - Get user     (empty body         -> UserResponse)
        \\ PUT    /users/:id        - Update user  (UpdateUserRequest  -> UserResponse)
        \\ DELETE /users/:id        - Delete user  (empty body         -> DeleteResponse)
    ;
}

// Copies a mapped row into a protobuf message. Both `email` fields are
// `?[]const u8`, so this is a straight assignment.
fn toProto(u: User) crud.User {
    return .{ .id = u.id, .name = u.name, .email = u.email };
}

// Reads the `:id` path param, returning null (and setting 400) on parse error.
fn parseId(ctx: *Context) ?i64 {
    const id_str = ctx.param("id");
    return std.fmt.parseInt(i64, id_str, 10) catch {
        ctx.response.setStatus(.bad_request);
        return null;
    };
}

fn createUser(ctx: *Context) !void {
    const req = (try ctx.bindProto(crud.CreateUserRequest)) orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };
    if (req.name.len == 0) {
        ctx.response.setStatus(.bad_request);
        return;
    }

    const row = (try ctx.SQL.queryRow(
        ctx,
        User,
        "INSERT INTO proto_users (name, email) VALUES ($1, $2) RETURNING id, name, email",
        .{ req.name, req.email },
    )) orelse {
        ctx.response.setStatus(.internal_server_error);
        return;
    };

    try ctx.protobuf(crud.UserResponse{ .user = toProto(row) });
}

fn listUsers(ctx: *Context) !void {
    const rows = try ctx.SQL.queryRows(
        ctx,
        User,
        "SELECT id, name, email FROM proto_users ORDER BY id",
        .{},
    );

    var list = try std.ArrayList(crud.User).initCapacity(ctx.allocator, rows.len);
    for (rows) |r| list.appendAssumeCapacity(toProto(r));

    try ctx.protobuf(crud.UserList{ .users = list });
}

fn getUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse return;

    const row = try ctx.SQL.queryRow(
        ctx,
        User,
        "SELECT id, name, email FROM proto_users WHERE id = $1",
        .{id},
    );

    if (row) |r| {
        try ctx.protobuf(crud.UserResponse{ .user = toProto(r) });
    } else {
        ctx.response.setStatus(.not_found);
    }
}

fn updateUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse return;

    const req = (try ctx.bindProto(crud.UpdateUserRequest)) orelse {
        ctx.response.setStatus(.bad_request);
        return;
    };
    if (req.name == null and req.email == null) {
        ctx.response.setStatus(.bad_request);
        return;
    }

    if (req.name) |n| {
        if (req.email) |e| {
            _ = try ctx.SQL.exec(
                ctx,
                "UPDATE proto_users SET name = $1, email = $2 WHERE id = $3",
                .{ n, e, id },
            );
        } else {
            _ = try ctx.SQL.exec(
                ctx,
                "UPDATE proto_users SET name = $1 WHERE id = $2",
                .{ n, id },
            );
        }
    } else if (req.email) |e| {
        _ = try ctx.SQL.exec(
            ctx,
            "UPDATE proto_users SET email = $1 WHERE id = $2",
            .{ e, id },
        );
    }

    const row = (try ctx.SQL.queryRow(
        ctx,
        User,
        "SELECT id, name, email FROM proto_users WHERE id = $1",
        .{id},
    )) orelse {
        ctx.response.setStatus(.not_found);
        return;
    };

    try ctx.protobuf(crud.UserResponse{ .user = toProto(row) });
}

fn deleteUser(ctx: *Context) !void {
    const id = parseId(ctx) orelse return;

    // Postgres reports the deleted row via RETURNING; `rowsAffected()` is not
    // reliably populated for this dialect, so detect the delete this way.
    const row = (try ctx.SQL.queryRow(
        ctx,
        User,
        "DELETE FROM proto_users WHERE id = $1 RETURNING id, name, email",
        .{id},
    )) orelse {
        ctx.response.setStatus(.not_found);
        return;
    };
    _ = row;

    try ctx.protobuf(crud.DeleteResponse{ .success = true });
}
