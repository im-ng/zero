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
    try app.post("/users", createUser);
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
        \\ NoSQL (document MongoDB) CRUD demo.
        \\ Pure-Zig OP_MSG client: no mongo-c-driver. Connects over OP_MSG with
        \\ SCRAM-SHA-256 auth (when MONGODB_USER is set) and optional TLS.
        \\ Routes (collection = "users"):
        \\   GET    /users            list users (find, limit 50)
        \\   GET    /users/:key       get a user by _id
        \\   PUT    /users/:key       upsert a user (request body = document JSON)
        \\   POST   /users/:key       upsert a user (request body = document JSON)
        \\   DELETE /users/:key       delete a user by _id
        \\   POST   /query            run a raw MongoDB command (request body = JSON)
        \\
        \\ Set MONGODB_CONTACT_POINTS / MONGODB_DB in configs/.env.
        \\
        \\ Statements are full MongoDB command documents supplied by the handler —
        \\ the datasource layer does not construct or hardcode any command.
    ;
}

/// Ensure the `users` collection exists. MongoDB creates collections lazily on
/// first write, but an explicit `create` makes the demo deterministic and lets
/// startup surface connectivity/auth errors early. `create` on an existing
/// collection replies with `ok:0`, which the wire client does not treat as a
/// Zig error, so this is idempotent and safe to call every startup.
fn ensureSchema(ctx: *Context) !void {
    const n = ctx.NoSQL orelse return;
    const r = n.query(ctx, "{\"create\":\"users\"}") catch return;
    ctx.allocator.free(r);
}

/// Escape `s` as a JSON string (doubles `"` and `\`).
fn jsonString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    try out.append('"');
    for (s) |c| {
        if (c == '"' or c == '\\') {
            try out.append('\\');
        }
        try out.append(c);
    }
    try out.append('"');
    return try out.toOwnedSlice();
}

/// Pull the first document out of a `find` reply's `cursor.firstBatch`. Returns
/// a freshly allocated JSON string, or `null` when the batch is empty / absent.
/// Caller frees the returned slice.
fn extractFirstDoc(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const cursor = root.object.get("cursor") orelse return null;
    if (cursor != .object) return null;
    const batch = cursor.object.get("firstBatch") orelse return null;
    if (batch != .array) return null;
    if (batch.array.items.len == 0) return null;
    return try std.json.Stringify.valueAlloc(alloc, batch.array.items[0], .{});
}

pub fn listUsers(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const cmd = "{\"find\":\"users\",\"projection\":{\"_id\":0},\"limit\":50}";
        const raw = n.query(ctx, cmd) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
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
        const key_json = try jsonString(ctx.allocator, key);
        defer ctx.allocator.free(key_json);
        var cmd = std.array_list.Managed(u8).init(ctx.allocator);
        defer cmd.deinit();
        try cmd.appendSlice("{\"find\":\"users\",\"filter\":{\"_id\":");
        try cmd.appendSlice(key_json);
        try cmd.appendSlice("},\"projection\":{\"_id\":0},\"limit\":1}");
        const cmd_slice = try cmd.toOwnedSlice();
        defer ctx.allocator.free(cmd_slice);
        const reply = n.query(ctx, cmd_slice) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
        defer ctx.allocator.free(reply);
        const doc = extractFirstDoc(ctx.allocator, reply) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
        if (doc) |d| {
            defer ctx.allocator.free(d);
            ctx.response.content_type = .JSON;
            try ctx.response.writer().writeAll(d);
        } else {
            ctx.response.setStatus(.not_found);
            try ctx.response.json(.{ .message = "not found", .key = key }, .{});
        }
    } else {
        notConfigured(ctx);
    }
}

pub fn createUser(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const value = ctx.request.body() orelse "{}";
        var cmd = std.array_list.Managed(u8).init(ctx.allocator);
        defer cmd.deinit();
        try cmd.appendSlice("{\"insert\":\"users\",\"documents\":[");
        try cmd.appendSlice(value);
        try cmd.appendSlice("]}");
        const cmd_slice = try cmd.toOwnedSlice();
        defer ctx.allocator.free(cmd_slice);
        const raw = n.query(ctx, cmd_slice) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
        defer ctx.allocator.free(raw);
        ctx.response.content_type = .JSON;
        try ctx.response.writer().writeAll(raw);
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
        const key_json = try jsonString(ctx.allocator, key);
        defer ctx.allocator.free(key_json);
        const value = ctx.request.body() orelse "{}";
        var cmd = std.array_list.Managed(u8).init(ctx.allocator);
        defer cmd.deinit();
        try cmd.appendSlice("{\"update\":\"users\",\"updates\":[{\"q\":{\"_id\":");
        try cmd.appendSlice(key_json);
        try cmd.appendSlice("},\"u\":{\"$set\":");
        try cmd.appendSlice(value);
        try cmd.appendSlice("},\"upsert\":true}]}");
        const cmd_slice = try cmd.toOwnedSlice();
        defer ctx.allocator.free(cmd_slice);
        _ = n.put(ctx, cmd_slice) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
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
        const key_json = try jsonString(ctx.allocator, key);
        defer ctx.allocator.free(key_json);
        var cmd = std.array_list.Managed(u8).init(ctx.allocator);
        defer cmd.deinit();
        try cmd.appendSlice("{\"delete\":\"users\",\"deletes\":[{\"q\":{\"_id\":");
        try cmd.appendSlice(key_json);
        try cmd.appendSlice("},\"limit\":0}]}");
        const cmd_slice = try cmd.toOwnedSlice();
        defer ctx.allocator.free(cmd_slice);
        n.delete(ctx, cmd_slice) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
        try ctx.response.json(.{ .status = "deleted", .key = key }, .{});
    } else {
        notConfigured(ctx);
    }
}

pub fn runQuery(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const cmd = ctx.request.body() orelse "";
        const raw = n.query(ctx, cmd) catch |e| {
            if (nosqlUpstreamError(ctx)) return;
            return e;
        };
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
    ctx.response.json(.{ .message = "MONGODB_CONTACT_POINTS / MONGODB_DB not configured" }, .{}) catch {};
}

/// Map a MongoDB upstream failure to an explicit error response. The datasource
/// records status/message on `ctx.NoSQL.lastError()`; surface it here whenever
/// the backend recorded one. Returns `true` when handled (response written).
fn nosqlUpstreamError(ctx: *Context) bool {
    const detail = ctx.NoSQL.?.lastError() orelse return false;
    ctx.response.setStatus(switch (detail.status) {
        401, 403 => .unauthorized,
        404 => .not_found,
        else => .bad_gateway,
    });
    ctx.response.json(.{ .err = "nosql_upstream_failed", .status = detail.status, .message = detail.message }, .{}) catch {};
    return true;
}
