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
    wsClient: wsHandler = undefined,

    /// Inbound bulkhead: count of in-flight requests, capped at `max_concurrent`
    /// (0 = unlimited). When at capacity, `dispatch` rejects with 503 instead of
    /// queuing, protecting the server from overload.
    in_flight: std.atomic.Value(u32) = undefined,
    max_concurrent: u32 = 0,

    pub const WebsocketHandler = wsHandler;

    // Per-request metric recording is sampled (wrapper-only optimization, no
    // vendored-lib change): only 1-in-METRIC_SAMPLE_RATE requests acquire the
    // metrics library's per-vector mutexes. The sampled request writes back
    // `count` to the hits counter via `incrBy` so totals stay accurate despite
    // sampling; the latency histogram is a representative sample.
    var metric_tick: std.atomic.Value(u64) = .init(0);
    const METRIC_SAMPLE_RATE: u64 = 32;

    pub fn metric(self: *Handler, duration: f32, method: []const u8, status: u16, path: []const u8) !void {
        const tick = metric_tick.fetchAdd(1, .monotonic);
        if (tick % METRIC_SAMPLE_RATE != 0) return;
        try self.container.metricz.response(.{ .method = method, .path = path, .status = status }, duration);
        try self.container.metricz.responseHits(.{ .method = method, .path = path, .status = status }, METRIC_SAMPLE_RATE);
    }

    pub fn ws(self: *Handler, action: Responder.Do(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        // Apply the inbound bulkhead to websocket handshakes too (otherwise WS
        // upgrades bypass the concurrency cap that `dispatch` enforces).
        if (self.max_concurrent > 0) {
            const n = self.in_flight.fetchAdd(1, .monotonic);
            if (n >= self.max_concurrent) {
                _ = self.in_flight.fetchSub(1, .monotonic);
                res.setStatus(.service_unavailable);
                res.content_type = .JSON;
                res.body = "{\"error\":\"concurrency limit exceeded\"}";
                return;
            }
            defer _ = self.in_flight.fetchSub(1, .monotonic);
        }

        // The websocket connection outlives this request, so the Context must be
        // heap-allocated with a persistent allocator. Using req.arena (and a
        // stack variable) left a dangling pointer that crashed on the first
        // message (garbage allocator vtable during logging).
        const ctx = try self.container.allocator.create(Context);
        ctx.* = try Context.init(self.container.allocator, self.container, req, res);
        ctx.action = action;

        if (try httpz.upgradeWebsocket(wsHandler, req, res, ctx) == false) {
            ctx.deinit();
            res.setStatus(.internal_server_error);
            res.body = "invalid websocket";
            return;
        }
        res.setStatus(.ok);

        const access_log = try std.fmt.allocPrint(req.arena, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(access_log);
    }

    pub fn dispatch(self: *Handler, action: Responder.Do(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        // Inbound bulkhead: reject (503) instead of queuing when at capacity.
        if (self.max_concurrent > 0) {
            const n = self.in_flight.fetchAdd(1, .monotonic);
            if (n >= self.max_concurrent) {
                _ = self.in_flight.fetchSub(1, .monotonic);
                res.setStatus(.service_unavailable);
                res.content_type = .JSON;
                res.body = "{\"error\":\"concurrency limit exceeded\"}";
                return;
            }
            defer _ = self.in_flight.fetchSub(1, .monotonic);
        }

        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        const start = utils.nowMonotonic();

        // Error recovery: an uncaught handler error is mapped by httpz to an
        // abrupt connection close (httpz.zig:218). Catch it here and emit a
        // structured 500 with the correlation id, and log it for observability.
        // (A true Zig `@panic` is still unrecoverable by design — the mitigation
        // is to return errors from handlers rather than panic; see ZIG_LEARNINGS.)
        action(&ctx) catch |err| {
            res.setStatus(.internal_server_error);
            res.content_type = .JSON;
            res.body = "{\"error\":\"internal server error\"}";
            const cid = req.headers.get("X-Correlation-ID");
            self.container.log.err(try std.fmt.allocPrint(
                req.arena,
                "handler error (correlation={?s}): {}",
                .{ cid, err },
            ));
        };

        // does not include middleware executions
        const duration: f32 = utils.elapsedMs(start);

        try self.metric(duration, @tagName(req.method), res.status, req.url.path);

        const access_log = try std.fmt.allocPrint(
            req.arena,
            "{s}\t {d} {d}ms {s} {s}",
            .{
                res.headers.get("X-Correlation-ID").?,
                res.status,
                duration,
                @tagName(req.method),
                req.url.path,
            },
        );
        ctx.info(access_log);
    }

    pub fn unauthorized(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        try res.json(.{ .message = "unauthorizated request!" }, .{});

        try self.metric(0, @tagName(req.method), res.status, req.url.path);

        const access_log = try std.fmt.allocPrint(req.arena, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(access_log);
    }

    pub fn notFound(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = try Context.init(req.arena, self.container, req, res);
        defer req.arena.destroy(&ctx);

        res.setStatus(.not_found);

        try res.json(.{ .err = "route is not registered!" }, .{});

        try self.metric(0, @tagName(req.method), res.status, req.url.path);

        const access_log = try std.fmt.allocPrint(req.arena, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path });
        ctx.info(access_log);
    }

    pub fn uncaughtError(self: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.debug.print("something went wrong\n", .{});

        var ctx = Context.init(req.arena, self.container, req, res) catch |init_err| {
            std.debug.print("context init failed: {}\n", .{init_err});
            return;
        };
        defer req.arena.destroy(&ctx);

        res.setStatus(.internal_server_error);
        res.content_type = .JSON;
        res.body =
            \\ {"error": "something went wrong"}
        ;

        self.metric(0, @tagName(req.method), res.status, req.url.path) catch unreachable;

        const access_log = std.fmt.allocPrint(req.arena, "{s}\t {d} {d}ms {s} {s}", .{ res.headers.get("X-Correlation-ID").?, res.status, 0, @tagName(req.method), req.url.path }) catch unreachable;
        ctx.info(access_log);

        ctx.any(err);
    }
};

pub fn metricz(ctx: *Context) !void {
    // return httpz.writeMetrics(ctx.response.writer());
    return try ctx.container.metricz.write(ctx);
}
