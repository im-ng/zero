const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");
const otel = @import("../otel.zig");

const tracz = @This();
const zul = root.zul;
const utils = root.utils;

allocator: std.mem.Allocator,
provider: *otel.Provider,

pub fn init(c: Config) !tracz {
    return .{
        .allocator = c.allocator,
        .provider = c.provider,
    };
}

pub fn execute(self: *const tracz, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // Reuse the caller's correlation ID if provided, otherwise mint a new one.
    const id = req.header("X-Correlation-ID") orelse blk: {
        const uuid = zul.UUID.v4(utils.io);
        const buf = try req.arena.alloc(u8, 36);
        break :blk uuid.toHexBuf(buf, .lower);
    };

    // Echo it on the response and stamp the inbound request so downstream
    // outbound calls (HTTP client, pub/sub) can read and propagate it.
    res.headers.add("X-Correlation-ID", id);
    req.headers.add("X-Correlation-ID", id);

    // OpenTelemetry: wrap the whole request in a server span. When the feature is
    // disabled the provider is inert and `startSpan` returns null (no overhead).
    var server_span: ?otel.Span = null;
    var tp_buf: [55]u8 = undefined;
    if (self.provider.enabled) {
        var parent: ?otel.ActiveSpan = null;

        // Continue an upstream trace if W3C traceparent is present.
        if (req.header("traceparent")) |tp| {
            parent = otel.parseTraceparent(tp);
        } else if (otel.traceIDFromHex(id)) |tid| {
            // No upstream context: reuse the correlation id as the trace id so the
            // OTel trace_id and the existing X-Correlation-ID stay in lockstep.
            parent = otel.ActiveSpan{
                .trace_id = tid,
                .span_id = otel.SpanID.zero(),
                .trace_flags = otel.TraceFlags.sampled(),
                .is_remote = false,
            };
        }

        if (try self.provider.startSpan(self.allocator, "HTTP", parent, .Server)) |span| {
            server_span = span;
            otel.pushSpan(otel.activeFromSpan(span.getContext()));

            const tp = otel.formatTraceparent(&tp_buf, span.getContext());
            const owned = try req.arena.dupe(u8, tp);
            res.headers.add("traceparent", owned);
        }
    }

    const result = executor.next();

        if (server_span) |*sp| {
            try sp.setAttribute("http.request.method", .{ .string = @tagName(req.method) });
            try sp.setAttribute("url.path", .{ .string = req.url.path });
            try sp.setAttribute("http.response.status_code", .{ .int = @as(i64, res.status) });

            if (res.status < 400) {
                sp.setStatus(otel.Status.ok());
            } else {
                sp.setStatus(otel.Status.error_with_description(""));
            }

            self.provider.endSpan(sp);
            sp.deinit();
            otel.popSpan();
        }

    return result;
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    provider: *otel.Provider,
};


// ===================== Tests =====================


test "tracz Config struct can be initialized" {
    const allocator = std.testing.allocator;
    var provider = otel.Provider{ .enabled = false };
    const cfg = Config{ .allocator = allocator, .provider = &provider };
    try std.testing.expectEqual(allocator, cfg.allocator);
}

test "tracz init returns struct with allocator" {
    const allocator = std.testing.allocator;
    var provider = otel.Provider{ .enabled = false };
    const cfg = Config{ .allocator = allocator, .provider = &provider };
    const t = try init(cfg);
    try std.testing.expectEqual(allocator, t.allocator);
}
