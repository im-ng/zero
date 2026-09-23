const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    app.onStartup(ensureSchema);

    try app.get("/", index);
    try app.get("/users", listUsers);
    try app.get("/users/:key", getUser);
    try app.put("/users/:key", putUser);
    try app.post("/users/:key", putUser);
    try app.delete("/users/:key", deleteUser);
    try app.post("/query", runQuery);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ NoSQL (wide-column Cassandra) CRUD demo.
        \\ Routes (collection = "users"):
        \\   GET    /users            list users (SELECT ... LIMIT 50)
        \\   GET    /users/:key       get a user by key
        \\   PUT    /users/:key       upsert a user (request body = value)
        \\   POST   /users/:key       upsert a user (request body = value)
        \\   DELETE /users/:key       delete a user by key
        \\   POST   /query            run raw CQL (request body)
        \\
        \\ Set CASSANDRA_CONTACT_POINTS / CASSANDRA_KEYSPACE in configs/.env.
        \\
        \\ Queries are built by the handler and passed to ctx.NoSQL verbatim —
        \\ the datasource layer does not construct or hardcode any statement.
    ;
}

/// Build the `users` table once per request if it does not yet exist. The
/// datasource no longer creates collections for us, so the application owns
/// its schema. `CREATE TABLE IF NOT EXISTS` is idempotent and cheap.
fn ensureSchema(ctx: *Context) !void {
    const n = ctx.NoSQL orelse return;
    const r = n.query(ctx, "CREATE TABLE IF NOT EXISTS users (id text PRIMARY KEY, data text)") catch return;
    ctx.allocator.free(r);
}

/// Escape a value for embedding inside a single-quoted CQL string by doubling
/// any literal single quote (Cassandra's only string quoting rule).
fn cqlLiteral(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    for (s) |c| {
        if (c == '\'') {
            try out.append('\'');
        }
        try out.append(c);
    }
    return try out.toOwnedSlice();
}

pub fn listUsers(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const raw = try n.query(ctx, "SELECT data FROM users LIMIT 50");
        defer ctx.allocator.free(raw);
        ctx.response.content_type = .JSON;
        try ctx.response.writer().writeAll(raw);
    } else {
        notConfigured(ctx);
    }
}

pub fn getUser(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const key = ctx.request.params.get("key") orelse {
            badRequest(ctx, "missing :key");
            return;
        };
        const cql = try std.fmt.allocPrint(ctx.allocator, "SELECT data FROM users WHERE id = '{s}'", .{key});
        defer ctx.allocator.free(cql);
        const doc = try n.get(ctx, cql);
        if (doc) |d| {
            defer ctx.allocator.free(d);
            try ctx.response.json(.{ .key = key, .doc = d }, .{});
        } else {
            ctx.response.setStatus(.not_found);
            try ctx.response.json(.{ .message = "not found", .key = key }, .{});
        }
    } else {
        notConfigured(ctx);
    }
}

pub fn putUser(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const key = ctx.request.params.get("key") orelse {
            badRequest(ctx, "missing :key");
            return;
        };
        const value = ctx.request.body() orelse "";
        const esc = try cqlLiteral(ctx.allocator, value);
        defer ctx.allocator.free(esc);
        const cql = try std.fmt.allocPrint(
            ctx.allocator,
            "INSERT INTO users (id, data) VALUES ('{s}', '{s}')",
            .{ key, esc },
        );
        defer ctx.allocator.free(cql);
        try n.put(ctx, cql);
        try ctx.response.json(.{ .status = "stored", .key = key }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn deleteUser(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const key = ctx.request.params.get("key") orelse {
            badRequest(ctx, "missing :key");
            return;
        };
        const cql = try std.fmt.allocPrint(ctx.allocator, "DELETE FROM users WHERE id = '{s}'", .{key});
        defer ctx.allocator.free(cql);
        try n.delete(ctx, cql);
        try ctx.response.json(.{ .status = "deleted", .key = key }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn runQuery(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const cql = ctx.request.body() orelse "";
        const raw = try n.query(ctx, cql);
        defer ctx.allocator.free(raw);
        ctx.response.content_type = .JSON;
        try ctx.response.writer().writeAll(raw);
    } else {
        notConfigured(ctx);
    }
}

fn badRequest(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.bad_request);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

fn notConfigured(ctx: *Context) void {
    ctx.response.setStatus(.not_implemented);
    ctx.response.json(.{ .message = "CASSANDRA_CONTACT_POINTS / CASSANDRA_KEYSPACE not configured" }, .{}) catch {};
}
