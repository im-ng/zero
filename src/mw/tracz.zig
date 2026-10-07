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
// arithmetic ops instead of the per-request CSPRNG syscall.
// This mirrors how OpenTelemetry seeds its own span/trace ID generator.
// The id is a 16-byte / 32-hex W3C-trace-id-shaped value (version + variant bits set)
// so it stays usable as an OpenTelemetry trace_id when no inbound traceparent is present.
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

    // Propagate the inbound W3C Baggage header onto the response and the
    // request so it survives the round-trip and is available to downstream calls.
    if (req.header("baggage")) |bg| {
        res.headers.add("baggage", bg);
        req.headers.add("baggage", bg);
    }

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

// ===================== Async trace propagation =====================
//
// A pub/sub message crosses an async boundary, so the in-flight request span
// does not automatically cover the consumer. We bridge it the W3C way: the
// publisher injects the active span's `traceparent` as a message header, and the
// consumer extracts it to parent a fresh span to the upstream trace.

/// Return the W3C `traceparent` of the currently active span (the in-flight
/// request span when publishing from a handler), duplicated into `allocator`,
/// or null when no span is active. Caller frees the slice. Publishers inject
/// the result so the trace survives the hop to the consumer.
pub fn currentTraceparent(allocator: std.mem.Allocator) ?[]u8 {
    const cur = otel.currentSpan() orelse return null;
    var buf: [55]u8 = undefined;
    const sc = otel.spanContextFromActive(allocator, cur);
    const tp = otel.formatTraceparent(&buf, sc);
    return allocator.dupe(u8, tp) catch null;
}

/// Start a span for an inbound pub/sub message. `traceparent` (if present and
/// well-formed) becomes the parent, continuing the upstream trace; otherwise a
/// fresh trace starts. The span is pushed onto the active-span stack so a
/// handler's own child spans parent correctly. Returns null when disabled or no
/// tracer is available. The caller must `endConsumeSpan` when done.
pub fn startConsumeSpan(allocator: std.mem.Allocator, provider: *otel.Provider, traceparent: ?[]const u8) ?otel.Span {
    if (!provider.enabled) return null;
    var parent: ?otel.ActiveSpan = null;
    if (traceparent) |tp| {
        parent = otel.parseTraceparent(tp);
    }
    const maybe_span = provider.startSpan(allocator, "MESSAGE", parent, .Consumer) catch return null;
    const span = maybe_span orelse return null;
    otel.pushSpan(otel.activeFromSpan(span.getContext()));
    return span;
}

/// End, pop, and free a span started by `startConsumeSpan` (no-op when null).
pub fn endConsumeSpan(provider: *otel.Provider, span: ?otel.Span) void {
    if (span) |s| {
        var sp = s;
        provider.endSpan(&sp);
        sp.deinit();
        otel.popSpan();
    }
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

test "currentTraceparent is null with no active span" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), currentTraceparent(allocator));
}

test "currentTraceparent formats the active span" {
    const allocator = std.testing.allocator;
    const tid = otel.TraceID.fromHex("00000000000000000000000000000001") catch unreachable;
    const sid = otel.SpanID.fromHex("0000000000000002") catch unreachable;
    otel.pushSpan(.{ .trace_id = tid, .span_id = sid, .trace_flags = otel.TraceFlags.sampled(), .is_remote = false });
    defer otel.popSpan();
    const tp = currentTraceparent(allocator);
    try std.testing.expect(tp != null);
    if (tp) |t| {
        try std.testing.expectEqual(@as(usize, 55), t.len);
        allocator.free(t);
    }
}

test "startConsumeSpan is a no-op when disabled" {
    const allocator = std.testing.allocator;
    var provider = otel.Provider{ .enabled = false };
    try std.testing.expectEqual(@as(?otel.Span, null), startConsumeSpan(allocator, &provider, null));
}
