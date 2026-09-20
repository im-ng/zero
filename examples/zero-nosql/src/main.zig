const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

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
        \\ Cassandra (NoSQL / wide-column) CRUD demo.
        \\ Routes (collection = "users"):
        \\   GET    /users            list users (SELECT ... LIMIT 50)
        \\   GET    /users/:key       get a user by key
        \\   PUT    /users/:key       upsert a user (request body = value)
        \\   POST   /users/:key       upsert a user (request body = value)
        \\   DELETE /users/:key       delete a user by key
        \\   POST   /query            run raw CQL (request body)
        \\
        \\ Set CASSANDRA_CONTACT_POINTS / CASSANDRA_KEYSPACE in configs/.env.
    ;
}

pub fn listUsers(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        // The Cassandra client runs raw CQL without qualifying the keyspace, so we
        // qualify it here from the configured keyspace.
        const ks = ctx.container.config.get("CASSANDRA_KEYSPACE");
        const cql = try std.fmt.allocPrint(ctx.allocator, "SELECT data FROM {s}.users LIMIT 50", .{ks});
        defer ctx.allocator.free(cql);
        const raw = try n.query(ctx, "users", cql);
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
        const doc = try n.get(ctx, "users", key);
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
        try n.put(ctx, "users", key, value);
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
        try n.delete(ctx, "users", key);
        try ctx.response.json(.{ .status = "deleted", .key = key }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn runQuery(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const cql = ctx.request.body() orelse "";
        const raw = try n.query(ctx, "users", cql);
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
