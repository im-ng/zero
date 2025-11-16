const std = @import("std");
const root = @import("zero.zig");
const Thread = std.Thread;
const httpz = root.httpz;
const constants = root.constants;
const Context = root.Context;
const Responder = root.responder;
const utils = root.utils;
const wsConnection = root.httpz.websocket.Conn;
const wsHandler = root.WSHandler;

const server = @This();
const Self = @This();

// recommended to have middleware logic inside
// custom dispatch methods against individual middlewares
pub const Handler = struct {
    _req: *httpz.Request = undefined,
    _res: *httpz.Response = undefined,
    container: *root.container = undefined,
    ctx: *Context = undefined,
    timer: std.time.Timer = undefined,
    wsClient: wsHandler = undefined,
    pub const WebsocketHandler = wsHandler;

    pub fn metric(self: *Handler, duration: f32, method: []const u8, status: u16, path: []const u8) !void {
        try self.container.metricz.response(.{ .method = method, .path = path, .status = status }, duration);
        try self.container.metricz.responseHits(.{ .method = method, .path = path, .status = status });
    }

    pub fn ws(self: *Handler, action: Responder.Do(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        ctx.action = action;

        if (try httpz.upgradeWebsocket(wsHandler, req, res, &ctx) == false) {
            res.setStatus(.internal_server_error);
            res.body = "invalid websocket";
            return;
        }
        res.setStatus(.ok);

        var buffer: []u8 = undefined;
        buffer = try req.arena.alloc(u8, 200);
        buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(buffer);
    }

    pub fn dispatch(self: *Handler, action: Responder.Do(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        var timer = try std.time.Timer.start();

        try action(&ctx);

        // does not include middleware executions
        const duration: f32 = @floatFromInt(timer.lap() / 1000000);

        try self.metric(duration, @tagName(req.method), res.status, req.url.path);

        var buffer: []u8 = undefined;
        buffer = try req.arena.alloc(u8, 200);
        buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, duration, @tagName(req.method), req.url.path });
        ctx.info(buffer);
    }

    pub fn unauthorized(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        try res.json(.{ .message = "unauthorizated request!" }, .{});

        try self.metric(0, @tagName(req.method), res.status, req.url.path);

        var buffer: []u8 = undefined;
        buffer = try req.arena.alloc(u8, 200);
        buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(buffer);
    }

    pub fn notFound(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        res.setStatus(.not_found);

        try res.json(.{ .err = "route is not registered!" }, .{});

        try self.metric(0, @tagName(req.method), res.status, req.url.path);

        var buffer: []u8 = undefined;
        buffer = try req.arena.alloc(u8, 200);
        buffer = try std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(buffer);
    }

    pub fn uncaughtError(self: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        res.setStatus(.internal_server_error);
        res.content_type = .JSON;
        res.body =
            \\ {"error": "something went wrong"}
        ;

        self.metric(0, @tagName(req.method), res.status, req.url.path) catch unreachable;

        var buffer: []u8 = undefined;
        buffer = req.arena.alloc(u8, 512) catch unreachable;
        buffer = std.fmt.bufPrint(buffer, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path }) catch unreachable;
        ctx.info(buffer);

        ctx.any(err);
    }
};

pub fn metricz(ctx: *Context) !void {
    // return httpz.writeMetrics(ctx.response.writer());
    return try ctx.container.metricz.write(ctx);
}
