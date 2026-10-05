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

    // Register KV backends conditionally: each wires only when its env is set,
    // so the example runs with the always-available memory store and lights up
    // sqlite / redis / nats as they become available.
    registerStores(app) catch |err| {
        app.container.log.err("kv store registration issue");
        app.container.log.any(err);
    };

    try app.get("/", index);
    try app.get("/kv/:store/:key", getKey);
    try app.put("/kv/:store/:key", setKey);
    try app.delete("/kv/:store/:key", delKey);

    try app.run();

    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

/// Wire the memory store (always available) plus any backend whose env is
/// present. `app.addKVStore` fails when the backing service is missing, so each
/// optional backend is guarded by its config key. The first store (memory)
/// becomes the default `ctx.KV`.
fn registerStores(app: *App) !void {
    const cfg = app.container.config;

    try app.addKVStore("mem", .memory, .{});

    if (std.mem.eql(u8, cfg.get("DB_DIALECT"), "sqlite")) {
        try app.addKVStore("sqlkv", .sqlite, .{});
    }

    if (!std.mem.eql(u8, cfg.get("REDIS_HOST"), "")) {
        try app.addKVStore("redis", .redis, .{});
    }

    if (std.mem.eql(u8, cfg.get("PUBSUB_BACKEND"), "nats")) {
        try app.addKVStore("natskv", .nats_kv, .{ .bucket = "zero-kv" });
    }
}

pub fn index(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ zero-kv: multi-backend KV pack (SQLite / Redis / NATS, plus memory).
        \\ Each backend wires only when its env is set; the memory store is always
        \\ present so the example runs with no external services.
        \\
        \\ Routes (store = "mem" | "sqlkv" | "redis" | "natskv"):
        \\   GET    /kv/:store/:key     get a value (404 if absent)
        \\   PUT    /kv/:store/:key     set a value (request body = value)
        \\   DELETE /kv/:store/:key     delete a value
        \\
        \\ Registered stores are listed in the startup log. With no backend env set,
        \\ only "mem" is available.
    ;
}

fn storeName(ctx: *Context) ?[]const u8 {
    return ctx.request.?.params.get("store");
}

fn keyName(ctx: *Context) ?[]const u8 {
    return ctx.request.?.params.get("key");
}

fn notFound(ctx: *Context, msg: []const u8) void {
    ctx.response.setStatus(.not_found);
    ctx.response.json(.{ .message = msg }, .{}) catch {};
}

pub fn getKey(ctx: *Context) !void {
    const store_name = storeName(ctx) orelse {
        notFound(ctx, "missing :store");
        return;
    };
    const key = keyName(ctx) orelse {
        notFound(ctx, "missing :key");
        return;
    };

    const store = ctx.GetKVStore(store_name) orelse {
        notFound(ctx, "unknown store (not registered)");
        return;
    };

    const value = store.get(ctx, key) catch |err| {
        ctx.response.setStatus(.bad_gateway);
        ctx.response.json(.{ .err = "kv_get_failed", .message = @errorName(err) }, .{}) catch {};
        return;
    };

    if (value) |v| {
        defer ctx.allocator.free(v);
        // Copy the owned value into the response buffer, then free it. Assigning
        // `body = v` directly would dangle once `v` is freed before the write.
        ctx.response.content_type = .TEXT;
        try ctx.response.writer().writeAll(v);
    } else {
        notFound(ctx, "key not found");
    }
}

pub fn setKey(ctx: *Context) !void {
    const store_name = storeName(ctx) orelse {
        notFound(ctx, "missing :store");
        return;
    };
    const key = keyName(ctx) orelse {
        notFound(ctx, "missing :key");
        return;
    };

    const store = ctx.GetKVStore(store_name) orelse {
        notFound(ctx, "unknown store (not registered)");
        return;
    };

    const value = ctx.request.?.body() orelse "";
    store.set(ctx, key, value) catch |err| {
        ctx.response.setStatus(.bad_gateway);
        ctx.response.json(.{ .err = "kv_set_failed", .message = @errorName(err) }, .{}) catch {};
        return;
    };
    try ctx.response.json(.{ .status = "stored", .store = store_name, .key = key }, .{});
}

pub fn delKey(ctx: *Context) !void {
    const store_name = storeName(ctx) orelse {
        notFound(ctx, "missing :store");
        return;
    };
    const key = keyName(ctx) orelse {
        notFound(ctx, "missing :key");
        return;
    };

    const store = ctx.GetKVStore(store_name) orelse {
        notFound(ctx, "unknown store (not registered)");
        return;
    };

    store.delete(ctx, key) catch |err| {
        ctx.response.setStatus(.bad_gateway);
        ctx.response.json(.{ .err = "kv_del_failed", .message = @errorName(err) }, .{}) catch {};
        return;
    };
    try ctx.response.json(.{ .status = "deleted", .store = store_name, .key = key }, .{});
}
