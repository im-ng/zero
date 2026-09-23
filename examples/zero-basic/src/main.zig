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

fn panic(msg: []const u8, return_address: ?usize) noreturn {
    _ = msg;
    std.log.err("=== Stack Trace ==============", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = return_address });
    std.process.exit(1);
}

const Query = struct {
    hello: *const fn (*Context, void) anyerror![]const u8,
};

fn helloResolver(_: *Context, _: void) anyerror![]const u8 {
    return "hello";
}

var query_root = Query{ .hello = helloResolver };

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.io, init.environ_map);

    app.onStartup(prepareDatasources);

    try app.addFileStore("local", .local, .{ .root = "./data/basic-store" });

    try app.get("/", index);

    try app.get("/text", textResponse);

    try app.get("/json", jsonResponse);

    try app.get("/db", dbResponse);

    try app.get("/keys", keys);

    try app.get("/memory", memoryUsage);

    try app.get("/proto", protoGet);

    try app.post("/proto", protoPost);

    try app.graphql("/graphql", Query, null, &query_root, null);

    try app.get("/filestore", filestoreGet);

    try app.post("/filestore", filestorePost);

    try app.get("/ts/write", tsWrite);

    try app.get("/ts/query", tsQuery);

    try app.get("/solr/index", solrIndex);

    try app.get("/solr/query", solrQuery);

    try app.get("/nosql/put", nosqlPut);

    try app.get("/nosql/get", nosqlGet);

    try app.get("/clickhouse/query", clickhouseQuery);

    try app.get("/clickhouse/write", clickhouseWrite);

    try app.get("/couchbase/put", couchbasePut);

    try app.get("/couchbase/get", couchbaseGet);

    try app.run();

    // Bail out if leak detected on load test
    if (gpa.detectLeaks() > 0) {
        std.process.exit(1);
    }
}

pub fn prepareDatasources(ctx: *Context) !void {
    _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS users (id INTEGER, name VARCHAR)", .{});
    _ = try ctx.SQL.exec(ctx, "INSERT INTO users SELECT 1, 'alice' WHERE NOT EXISTS (SELECT 1 FROM users)", .{});
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
    ctx.info("debug message");

    ctx.response.setStatus(.ok);
    ctx.response.body =
        \\ We are seeing the test content from zero framework
    ;
}

pub fn textResponse(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .TEXT;
    ctx.response.body = "plain text response from zero framework";
}

// Minimal protobuf endpoint. The `protobuf` module is re-exported by `zero`
// (`zero.protobuf`), but a tiny hand-encoded message keeps this example free of
// generated structs.
// TestMsg { value: string } field 1, wire type 2 (length-delimited).
fn protoBytes() [7]u8 {
    return [_]u8{ 0x0a, 0x05, 'h', 'e', 'l', 'l', 'o' };
}

pub fn protoGet(ctx: *Context) !void {
    ctx.response.header("content-type", "application/x-protobuf");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(&protoBytes());
}

pub fn protoPost(ctx: *Context) !void {
    const body = ctx.request.body() orelse "";
    ctx.response.header("content-type", "application/x-protobuf");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(body);
}

pub fn filestoreGet(ctx: *Context) !void {
    const key = blk: {
        const qs = ctx.request.query() catch break :blk "seed";
        break :blk qs.get("key") orelse "seed";
    };
    const got = (try ctx.GetFileFromStore("local", key)) orelse "";
    ctx.response.header("content-type", "application/octet-stream");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(got);
}

pub fn filestorePost(ctx: *Context) !void {
    const payload = "filestore-payload";
    const key = try utils.combine(ctx.allocator, "k-{d}", .{std.c.getpid()});
    try ctx.SaveFileToStore("local", key, payload);
    const got = (try ctx.GetFileFromStore("local", key)) orelse {
        ctx.response.setStatus(.internal_server_error);
        return;
    };
    ctx.response.header("content-type", "application/octet-stream");
    ctx.response.setStatus(.ok);
    try ctx.response.writer().writeAll(got);
    try ctx.DeleteFileFromStore("local", key);
}

pub fn keys(ctx: *Context) !void {
    ctx.info("debug message");

    const pk =
        \\     {
        \\   "keys": [
        \\      {
        \\        "kty": "RSA",
        \\        "e": "AQAB",
        \\        "use": "sig",
        \\        "kid": "zero-framework-app",
        \\        "alg": "RS256",
        \\        "n": "i_RCaAfs93TKxeqaoExGcKsQLHjS9s4A8Eujcwv9g-9Qk5pPLm6jXb2AHIwPnbEvOEJvs8KY8hFHrQzp8PYsfc24Z_MY1MzJ7bdGNzCxzPViXcoljdWXAOzRIjpRTF0rF77nY1qbuRs5CefVgjwxrEOIQngrTqstAdMZlPm5_BQXKgop2REVAJF4VZAIR7-X9nOoSNFJewMpzxpwK3zqdnIF9sPf-uN5pLf4t07-teyr8EdO2enDVj1jaxiHadfCEENtL5FpRaVA5JpEIpnb1NJx0D9r9wdCo3jjUNTbyNUVxjI0Spm9pfk5G3Ma02u4STCs2B4PeP8F9a4UM5NlWw"
        \\      }
        \\   ]
        \\ }
    ;
    ctx.response.setStatus(.ok);
    ctx.response.content_type = .JSON;
    ctx.response.body = pk;
}

pub fn jsonResponse(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    try ctx.response.json(.{ .msg = "hello world!" }, .{});
}

const User = struct {
    id: i32,
    name: []const u8,
};

pub fn dbResponse(ctx: *Context) !void {
    const user = try ctx.SQL.queryRow(ctx, User, "SELECT id, name FROM users LIMIT 1", .{});
    if (user) |u| {
        defer ctx.allocator.free(u.name);
        try ctx.response.json(u, .{});
    } else {
        try ctx.response.json(.{ .id = 0, .name = "nobody" }, .{});
    }
}

// --- Round 1: time-series (InfluxDB) ---

pub fn tsWrite(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        try ts.write(ctx, "demo,host=example value=1.0");
        try ctx.response.json(.{ .status = "written" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "INFLUXDB_URL not configured" }, .{});
    }
}

pub fn tsQuery(ctx: *Context) !void {
    if (ctx.Timeseries) |ts| {
        const csv = try ts.query(ctx, "from(bucket:\"metrics\") |> range(start:-1h)");
        defer ctx.allocator.free(csv);
        try ctx.response.json(.{ .csv = csv }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "INFLUXDB_URL not configured" }, .{});
    }
}

pub fn solrIndex(ctx: *Context) !void {
    if (ctx.Search) |s| {
        try s.index(ctx, "demo", "{\"id\":\"1\",\"title\":\"example\"}");
        try ctx.response.json(.{ .status = "indexed" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "SOLR_URL not configured" }, .{});
    }
}

pub fn solrQuery(ctx: *Context) !void {
    if (ctx.Search) |s| {
        const hits = try s.query(ctx, "demo", "title:example");
        defer ctx.allocator.free(hits);
        try ctx.response.json(.{ .hits = hits }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "SOLR_URL not configured" }, .{});
    }
}

pub fn nosqlPut(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        try n.put(ctx, "INSERT INTO users (id, data) VALUES ('alice', '{\"age\":30}')");
        try ctx.response.json(.{ .status = "stored" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CASSANDRA_CONTACT_POINTS not configured" }, .{});
    }
}

pub fn nosqlGet(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const doc = try n.get(ctx, "SELECT data FROM users WHERE id = 'alice'");
        if (doc) |d| {
            defer ctx.allocator.free(d);
            try ctx.response.json(.{ .doc = d }, .{});
        } else {
            try ctx.response.json(.{ .doc = null }, .{});
        }
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CASSANDRA_CONTACT_POINTS not configured" }, .{});
    }
}

pub fn clickhouseWrite(ctx: *Context) !void {
    if (ctx.container.ClickHouse) |_| {
        const name: []const u8 = "alice";
        _ = try ctx.SQL.exec(ctx, "CREATE TABLE IF NOT EXISTS events (id Int64, name String)", .{});
        _ = try ctx.SQL.exec(ctx, "INSERT INTO events (id, name) VALUES (?, ?)", .{ @as(i64, 1), name });
        try ctx.response.json(.{ .status = "stored" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CLICKHOUSE_URL not configured" }, .{});
    }
}

pub fn clickhouseQuery(ctx: *Context) !void {
    if (ctx.container.ClickHouse) |_| {
        const Event = struct { id: i64, name: []const u8 };
        const row = try ctx.SQL.queryRow(ctx, Event, "SELECT id, name FROM events LIMIT 1", .{});
        if (row) |r| {
            try ctx.response.json(.{ .event = r }, .{});
        } else {
            try ctx.response.json(.{ .event = null }, .{});
        }
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "CLICKHOUSE_URL not configured" }, .{});
    }
}

pub fn couchbasePut(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        try n.put(ctx, "INSERT INTO users (id, data) VALUES ('alice', '{\"age\":30}')");
        try ctx.response.json(.{ .status = "stored" }, .{});
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "COUCHBASE_CONTACT_POINTS not configured" }, .{});
    }
}

pub fn couchbaseGet(ctx: *Context) !void {
    if (ctx.NoSQL) |n| {
        const doc = try n.get(ctx, "SELECT data FROM users WHERE id = 'alice'");
        if (doc) |d| {
            defer ctx.allocator.free(d);
            try ctx.response.json(.{ .doc = d }, .{});
        } else {
            try ctx.response.json(.{ .doc = null }, .{});
        }
    } else {
        ctx.response.setStatus(.not_implemented);
        try ctx.response.json(.{ .message = "COUCHBASE_CONTACT_POINTS not configured" }, .{});
    }
}
