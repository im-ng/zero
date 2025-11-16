const std = @import("std");
const root = @import("../zero.zig");
const Self = @This();
const Client = @This();

const constants = root.constants;
const Context = root.Context;
const conainer = root.container;
const Responder = root.responder;
const utils = root.utils;
const Headers = std.http.Client.Request.Headers;
const ClientError = root.Error.ClientError;
const zul = root.zul;

container: *root.container = undefined,
client: zul.http.Client,
arena: *std.heap.ArenaAllocator,
url: ?[]const u8 = undefined,
name: []const u8 = undefined,

pub fn create(
    ct: *root.container,
    service_name: []const u8,
    _url: []const u8,
) !*Client {
    // const arena: *std.heap.ArenaAllocator = try ct.allocator.create(std.heap.ArenaAllocator);
    // errdefer ct.allocator.destroy(arena);

    // arena.* = std.heap.ArenaAllocator.init(ct.allocator);
    // errdefer arena.deinit();

    const c = try ct.allocator.create(Client);
    // errdefer ct.allocator.destroy(c);

    c.client = zul.http.Client.init(ct.allocator);
    c.name = service_name;
    c.container = ct;
    c.url = _url;
    // c.arena = arena;

    return c;
}

pub fn deinit(self: *Self) void {
    const arena = self._arena;
    const allocator = arena.child_allocator;
    arena.deinit();
    allocator.destroy(arena);
}

pub fn metric(
    self: *Self,
    duration: f32,
    method: []const u8,
    status: u16,
    path: []const u8,
) !void {
    try self.container.metricz.clientResponse(.{
        .method = method,
        .path = path,
        .status = status,
    }, duration);
}

pub fn log(
    _: *Self,
    ctx: *Context,
    traceId: []const u8,
    duration: f32,
    method: []const u8,
    status: u16,
    path: []const u8,
) !void {
    var buffer: []u8 = undefined;
    buffer = try ctx.allocator.alloc(u8, 200);
    buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ traceId, status, duration, method, path });
    ctx.info(buffer);
}

pub fn get(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.GET,
        path,
        queryParams,
        headers,
        null,
        response,
    );
}

pub fn post(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.POST,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

pub fn put(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.PUT,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

pub fn delete(
    self: *Self,
    ctx: *Context,
    comptime response: type,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
) !?response {
    return self.createAndSendRequest(
        ctx,
        std.http.Method.DELETE,
        path,
        queryParams,
        headers,
        payload,
        response,
    );
}

fn createAndSendRequest(
    self: *Self,
    ctx: *Context,
    method: std.http.Method,
    path: []const u8,
    queryParams: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap([]const u8),
    payload: ?[]const u8,
    comptime response: type,
) !?response {
    var absoluteURL = self.url.?;
    defer ctx.allocator.destroy(&absoluteURL);

    if (path.len > 0) {
        absoluteURL = try utils.combine(
            ctx.allocator,
            "{s}{s}",
            .{ self.url.?, path },
        );
    }

    var req = try self.client.allocRequest(ctx.allocator, absoluteURL);
    defer req.deinit();

    req.method = method;

    if (queryParams) |params| {
        var iterator = params.iterator();
        while (iterator.next()) |param| {
            try req.query(param.key_ptr.*, param.value_ptr.*);
        }
    }

    if (headers) |custom_headers| {
        var iterator = custom_headers.iterator();
        while (iterator.next()) |header| {
            try req.header(header.key_ptr.*, header.value_ptr.*);
        }
    }

    if (payload) |body| {
        req.body(body);
    }

    var timer = try std.time.Timer.start();

    var res = try req.getResponse(.{});

    const elapsed: f32 = @floatFromInt(timer.lap() / 1000000);

    switch (res.status) { //expand more
        404 => {
            return ClientError.EntityNotFound;
        },
        500...600 => {
            return ClientError.ServiceNotReachable;
        },
        else => {
            // do nothing
        },
    }

    const responseTraceID = res.header("X-Correlation-ID");
    var traceID = try self.getResponseTraceIDBuffer(ctx.allocator);
    defer ctx.allocator.destroy(&traceID);
    if (responseTraceID) |_id| {
        traceID = _id;
    }

    const parsed = try res.json(
        response,
        ctx.allocator,
        .{},
    );
    defer parsed.deinit();

    try self.metric(elapsed, @tagName(method), res.status, absoluteURL);

    try self.log(
        ctx,
        traceID,
        elapsed,
        @tagName(method),
        res.status,
        absoluteURL,
    );

    return parsed.value;
}

fn getResponseTraceIDBuffer(_: *Self, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: []u8 = undefined;
    buffer = try allocator.alloc(u8, 36);
    buffer = try std.fmt.bufPrint(buffer, "{s:>36}", .{" "});
    return buffer;
}
