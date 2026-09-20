const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const migrate = zero.migrate;
const utils = zero.utils;

// ---- Domain model ----
// Struct fields map 1:1 to Postgres columns for the pg Mapper.
const User = struct {
    id: i64,
    name: []const u8,
    email: ?[]const u8,
};

// ---- GraphQL types (resolver structs) ----
// Constant fields are returned as-is; function fields are invoked as
// resolvers with the signature `fn(*Context, Args) !Return`.
const Query = struct {
    users: *const fn (*Context, void) anyerror![]User,
    user: *const fn (*Context, UserArgs) anyerror!?User,
};

const UserArgs = struct {
    id: i64,
};

const Mutation = struct {
    createUser: *const fn (*Context, CreateUserArgs) anyerror!User,
    updateUser: *const fn (*Context, UpdateUserArgs) anyerror!?User,
    deleteUser: *const fn (*Context, DeleteUserArgs) anyerror!bool,
};

const CreateUserArgs = struct {
    name: []const u8,
    email: ?[]const u8,
};

const UpdateUserArgs = struct {
    id: i64,
    name: ?[]const u8,
    email: ?[]const u8,
};

const DeleteUserArgs = struct {
    id: i64,
};

// ---- Resolvers (db-backed) ----

fn usersResolver(ctx: *Context, _: void) anyerror![]User {
    return try ctx.SQL.queryRows(ctx, User, "SELECT id, name, email FROM users ORDER BY id", .{});
}

fn userResolver(ctx: *Context, args: UserArgs) anyerror!?User {
    return try ctx.SQL.queryRow(ctx, User, "SELECT id, name, email FROM users WHERE id = $1", .{args.id});
}

fn createUserResolver(ctx: *Context, args: CreateUserArgs) anyerror!User {
    // INSERT ... RETURNING returns the row, which we map straight back to User.
    return (try ctx.SQL.queryRow(ctx, User,
        \\INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id, name, email
    , .{ args.name, args.email })).?;
}

fn updateUserResolver(ctx: *Context, args: UpdateUserArgs) anyerror!?User {
    // Partial update: only set the fields that were actually provided. The
    // query strings are comptime-known, so we branch over the runtime optionals.
    if (args.name != null and args.email != null) {
        _ = try ctx.SQL.exec(ctx, "UPDATE users SET name = $1, email = $2 WHERE id = $3", .{ args.name.?, args.email.?, args.id });
    } else if (args.name != null) {
        _ = try ctx.SQL.exec(ctx, "UPDATE users SET name = $1 WHERE id = $2", .{ args.name.?, args.id });
    } else if (args.email != null) {
        _ = try ctx.SQL.exec(ctx, "UPDATE users SET email = $1 WHERE id = $2", .{ args.email.?, args.id });
    }
    return try ctx.SQL.queryRow(ctx, User, "SELECT id, name, email FROM users WHERE id = $1", .{args.id});
}

fn deleteUserResolver(ctx: *Context, args: DeleteUserArgs) anyerror!bool {
    // Map via the full User shape (pgz maps columns positionally, so the
    // SELECT must cover every struct field).
    if ((try ctx.SQL.queryRow(ctx, User, "SELECT id, name, email FROM users WHERE id = $1", .{args.id})) == null) {
        return false;
    }
    _ = try ctx.SQL.exec(ctx, "DELETE FROM users WHERE id = $1", .{args.id});
    return true;
}

// ---- Migration: create the users table ----

pub fn createUsersTable(c: *Context) anyerror!void {
    _ = try c.SQL.exec(c,
        \\DROP TABLE IF EXISTS users;
        \\CREATE TABLE users (
        \\    id BIGSERIAL PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    email TEXT
        \\)
    , .{});
}

const createUsersMigration = &migrate{
    .migrationNumber = 1760947200,
    .run = createUsersTable,
};

var query_root = Query{
    .users = usersResolver,
    .user = userResolver,
};

var mutation_root = Mutation{
    .createUser = createUserResolver,
    .updateUser = updateUserResolver,
    .deleteUser = deleteUserResolver,
};

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    try app.get("/", index);

    // Register the migration and run it explicitly (app.run() does not
    // auto-run migrations; re-runs are skipped via the zero_migrations table).
    const key = try utils.toStringFromInt(app.container.allocator, "{d}", createUsersMigration.migrationNumber);
    try app.addMigration(key, createUsersMigration);
    try app.runMigrations();

    // GraphQL-over-HTTP endpoint. POST {"query":"...","variables":{...}} or
    // GET /graphql?query=...  (queries and mutations both supported).
    try app.graphql("/graphql", Query, Mutation, &query_root, &mutation_root);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\GraphQL CRUD over Postgres.
        \\POST a query/mutation to /graphql, e.g.:
        \\  {"query":"{ users { id name email } }"}
        \\  {"query":"mutation { createUser(name:\"Bob\", email:\"bob@x.com\") { id name email } }"}
    ;
}
