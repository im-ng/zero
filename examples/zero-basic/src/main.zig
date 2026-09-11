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

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const app = try App.new(allocator, init.environ_map);

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

// Minimal protobuf endpoint (raw bytes; the `protobuf` module is not re-exported
// by `zero`, so a hand-encoded message stands in for ctx.protobuf here).
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

const Query = struct {
    hello: *const fn (*Context, void) anyerror![]const u8,
};
fn helloResolver(_: *Context, _: void) anyerror![]const u8 {
    return "hello";
}
var query_root = Query{ .hello = helloResolver };

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
    const stmt = "select id, name from users limit 1";

    const user = try ctx.SQL.queryRow(ctx, User, stmt, .{}) orelse unreachable;

    try ctx.response.json(user, .{});
}
