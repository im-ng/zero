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
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.io, init.environ_map);

    // Supabase is config-driven — no code difference vs a plain Postgres app,
    // because the Supabase SQL backend *is* Postgres with forced SSL, and the
    // Storage file store is the S3-compatible backend reusing SUPABASE_STORAGE_*
    // keys. Set these before startup (see configs/.env.example):
    //   SQL:
    //     DB_DIALECT=supabase
    //     SUPABASE_DB_HOST=aws-0-us-east-1.pooler.supabase.com
    //     SUPABASE_DB_PORT=5432
    //     SUPABASE_DB_USER=postgres.<project-ref>
    //     SUPABASE_DB_PASSWORD=...
    //     SUPABASE_DB_NAME=postgres
    //     SUPABASE_DB_SSL_MODE=require
    //   Storage:
    //     FILE_STORE_BACKEND=supabase
    //     SUPABASE_STORAGE_PROJECT=<ref>.supabase.co
    //     SUPABASE_STORAGE_BUCKET=uploads
    //     SUPABASE_STORAGE_ACCESS_KEY=...   (S3-compatible keys)
    //     SUPABASE_STORAGE_SECRET_KEY=...
    app.onStartup(prepareDatasources);

    try app.addFileStore("uploads", .supabase, .{});

    try app.get("/", indexHandler);
    try app.post("/messages", postMessage);
    try app.get("/messages", listMessages);
    try app.post("/upload", uploadHandler);

    try app.run();
}

fn prepareDatasources(ctx: *Context) !void {
    // Table lives in the Supabase project's `public` schema.
    _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS messages (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, body TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())", .{});
}

fn indexHandler(ctx: *Context) !void {
    try ctx.json(.{ .ok = true, .hint = "POST /messages {\"body\":\"...\"}, GET /messages, POST /upload (multipart)" });
}

const Message = struct {
    id: i64,
    body: []const u8,
};

fn postMessage(ctx: *Context) !void {
    const payload = struct { body: []const u8 };
    const inBody = (try ctx.bind(payload)) orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .@"error" = "need JSON body {\"body\": \"...\"}" });
        return;
    };
    if (inBody.body.len == 0) {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .@"error" = "'body' must not be empty" });
        return;
    }
    _ = try ctx.SQL.exec(ctx, "INSERT INTO messages (body) VALUES (?)", .{inBody.body});
    try ctx.json(.{ .queued = inBody.body.len });
}

fn listMessages(ctx: *Context) !void {
    // queryRows allocates the row slice (and owned string fields) on ctx.allocator.
    const rows = try ctx.SQL.queryRows(ctx, Message, "SELECT id, body FROM messages ORDER BY id DESC LIMIT 50", .{});
    defer ctx.allocator.free(rows);
    for (rows) |row| {
        defer ctx.allocator.free(row.body);
    }
    try ctx.json(rows);
}

fn uploadHandler(ctx: *Context) !void {
    const f = (try ctx.GetFile("file")) orelse {
        ctx.response.setStatus(.bad_request);
        try ctx.json(.{ .@"error" = "no 'file' field in multipart form" });
        return;
    };

    try ctx.SaveFileToStore("uploads", f.filename, f.data);
    try ctx.json(.{ .stored = f.filename, .bytes = f.size });
}
