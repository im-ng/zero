const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");
const otel = @import("../otel.zig");

const tracz = @This();
const utils = root.utils;

allocator: std.mem.Allocator,
provider: *otel.Provider,

// Fast correlation-id generator. A per-thread PRNG is seeded once from the
// monotonic clock plus this thread's address, so minting an id costs a few
// arithmetic ops instead of the per-request CSPRNG syscall that
// `zul.UUID.v4(utils.io)` paid. This mirrors how OpenTelemetry seeds its own
// span/trace ID generator (otel.zig:78-86). The id is a 16-byte / 32-hex
// W3C-trace-id-shaped value (version + variant bits set) so it stays usable as
// an OpenTelemetry trace_id when no inbound traceparent is present.
threadlocal var tl_prng: std.Random.DefaultPrng = undefined;
threadlocal var tl_prng_inited: bool = false;

fn nextCorrelationId(arena: std.mem.Allocator) ![]u8 {
    if (!tl_prng_inited) {
        const mono = utils.nowMonotonic();
        const seed: u64 =
            @as(u64, @intCast(mono.nanoseconds)) +%
            @intFromPtr(&tl_prng);
        tl_prng = std.Random.DefaultPrng.init(seed);
        tl_prng_inited = true;
    }
    var raw: [16]u8 = undefined;
    tl_prng.random().bytes(&raw);
    // W3C trace-id shape (version + variant bits).
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const buf = try arena.alloc(u8, 32);
    hexEncode(&raw, buf);
    return buf;
}

fn hexEncode(raw: *const [16]u8, out: []u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        out[i * 2] = digits[raw[i] >> 4];
        out[i * 2 + 1] = digits[raw[i] & 0x0f];
    }
}

pub fn init(c: Config) !tracz {
    return .{
        .allocator = c.allocator,
        .provider = c.provider,
    };
}

pub fn execute(self: *const tracz, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // Reuse the caller's correlation ID if provided, otherwise mint a new one.
    const id = req.header("X-Correlation-ID") orelse try nextCorrelationId(req.arena);

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
