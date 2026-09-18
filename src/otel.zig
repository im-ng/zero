const std = @import("std");

const sdk = @import("opentelemetry-sdk");

const api = sdk.api;
const trace_api = api.trace;

pub const Span = trace_api.Span;
pub const SpanContext = trace_api.SpanContext;
pub const TraceID = trace_api.TraceID;
pub const SpanID = trace_api.SpanID;
pub const TraceFlags = trace_api.TraceFlags;
pub const SpanKind = trace_api.SpanKind;
pub const Status = trace_api.Status;
const InstrumentationScope = sdk.InstrumentationScope;
const Context = api.context.Context;
const EnvMap = std.process.Environ.Map;

pub const log = std.log.scoped(.otel);

/// Lightweight, allocation-free handle to the currently-active span. Carries only
/// what is needed to parent a new span (trace/span ids + flags); the SDK-owned
/// `TraceState` is intentionally omitted (no W3C tracestate is emitted in v1).
pub const ActiveSpan = struct {
    trace_id: TraceID,
    span_id: SpanID,
    trace_flags: TraceFlags,
    is_remote: bool = false,
};

/// App-wide OpenTelemetry provider. When `enabled` is false every method is a
/// no-op and no SDK objects are allocated — so the experimental feature costs
/// nothing when `OTEL_EXPERIMENTAL` is unset.
pub const Provider = struct {
    enabled: bool = false,

    config: ?*sdk.otlp.ConfigOptions = null,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    server_scope: InstrumentationScope = undefined,
    prng: ?*std.Random.DefaultPrng = null,
    tracer_provider: ?*sdk.trace.TracerProvider = null,
    tracer: ?*trace_api.TracerImpl = null,
    otlp_exporter: ?*sdk.trace.OTLPExporter = null,
    batch_processor: ?*sdk.trace.BatchingProcessor = null,

    logger: ?*sdk.logs.Logger = null,
    logger_provider: ?*sdk.logs.LoggerProvider = null,
    log_processor: ?*sdk.logs.BatchingLogRecordProcessor = null,
    log_exporter: ?*sdk.logs.OTLPExporter = null,
    log_config: ?*sdk.otlp.ConfigOptions = null,

    /// Build the provider. `em` is the process environment map; the SDK reads
    /// `OTEL_EXPORTER_OTLP_*` from it automatically. When `enabled` is false the
    /// returned provider is inert.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, em: *EnvMap, enabled: bool) !Provider {
        var p: Provider = .{
            .enabled = enabled,
            .allocator = allocator,
            .io = io,
        };
        if (!enabled) return p;

        // Make the SDK honor OTEL_* config (service.name resource, sampler,
        // propagators, resource attributes). The vendored SDK never sets the
        // global Configuration singleton, so without this spans/logs render as
        // `unknown_service` and OTEL_TRACES_SAMPLER is a no-op. Derive
        // service.name from APP_NAME (falling back to the standard
        // OTEL_SERVICE_NAME if present, else "zero") so no new config keys are
        // required.
        if (sdk.config.Configuration.get() == null) {
            if (em.get("OTEL_SERVICE_NAME") == null) {
                const app_name = try allocator.dupe(u8, em.get("APP_NAME") orelse "zero");
                try em.put("OTEL_SERVICE_NAME", app_name);
            }
            const cfg = try sdk.config.Configuration.init(allocator, io, em);
            sdk.config.Configuration.set(cfg);
        }

        // Seed the ID generator from the monotonic clock (no std.crypto.random in 0.16).
        // Uses std.Io.Timestamp (portable monotonic nanos) rather than a
        // platform-specific clock_gettime/timespec, so this compiles on Linux and macOS.
        const mono = std.Io.Timestamp.now(io, .awake);
        const seed: u64 = @as(u64, @intCast(mono.nanoseconds));

        // The ID generator stores a `std.Random` interface that points at `prng`,
        // so `prng` must live for the provider's whole lifetime — heap-allocate it.
        p.prng = try allocator.create(std.Random.DefaultPrng);
        p.prng.?.* = std.Random.DefaultPrng.init(seed);
        const id_generator = sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(p.prng.?.random()) };

        p.tracer_provider = try sdk.trace.TracerProvider.init(allocator, io, id_generator);
        p.config = try sdk.otlp.ConfigOptions.init(allocator, em);
        p.otlp_exporter = try sdk.trace.OTLPExporter.init(allocator, io, p.config.?);
        p.batch_processor = try sdk.trace.BatchingProcessor.init(allocator, io, p.otlp_exporter.?.asSpanExporter(), .{});
        try p.tracer_provider.?.addSpanProcessor(p.batch_processor.?.asSpanProcessor());

        p.server_scope = .{
            .name = "zero.server",
            .version = "0.0.2",
            .schema_url = "https://opentelemetry.io/schemas/1.21.0",
        };
        p.tracer = try p.tracer_provider.?.getTracer(p.server_scope);

        // Logs: a parallel OTLP exporter that runs alongside the existing stdout
        // writer. When no collector is reachable the background exporter logs (and
        // drops) — the app keeps logging locally regardless.
        p.log_config = try sdk.otlp.ConfigOptions.init(allocator, em);
        p.log_exporter = try sdk.logs.OTLPExporter.init(allocator, io, p.log_config.?);
        p.log_processor = try sdk.logs.BatchingLogRecordProcessor.init(
            allocator,
            io,
            p.log_exporter.?.asLogRecordExporter(),
            .{},
        );
        p.logger_provider = try sdk.logs.LoggerProvider.init(allocator, io, null);
        try p.logger_provider.?.addLogRecordProcessor(p.log_processor.?.asLogRecordProcessor());
        p.logger = try p.logger_provider.?.getLogger(p.server_scope);
        active_log_logger = p.logger;
        logs_export_enabled = true;

        // Auth + custom OTLP headers. The vendored SDK's ConfigOptions does not
        // read these from env (see its mergeFromEnvMap TODO), so we install them
        // here. Both exporters receive the same set.
        //   OTEL_EXPORTER_OTLP_AUTH_HEADER : bare credential, e.g. "Bearer <token>"
        //       or "Basic <b64>" — mapped to the standard `Authorization` header.
        //   OTEL_EXPORTER_OTLP_HEADERS     : raw "Key=Value,..." custom headers.
        try applyOtlpHeaders(allocator, em, p.config.?);
        try applyOtlpHeaders(allocator, em, p.log_config.?);

        return p;
    }

    // Reads OTLP auth/custom headers from the env map and installs them on a
    // ConfigOptions instance. `config.headers` is consumed by the SDK's exporter
    // on every send. We dupe into `allocator` and free it in `shutdown`.
    fn applyOtlpHeaders(allocator: std.mem.Allocator, em: *EnvMap, config: *sdk.otlp.ConfigOptions) !void {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        // Bare credential -> Authorization: <value>.
        if (em.get("OTEL_EXPORTER_OTLP_AUTH_HEADER")) |auth| {
            if (auth.len > 0) {
                try buf.appendSlice(allocator, "Authorization=");
                try buf.appendSlice(allocator, auth);
            }
        }
        // Raw custom headers ("Key=Value,...").
        if (em.get("OTEL_EXPORTER_OTLP_HEADERS")) |h| {
            if (h.len > 0) {
                if (buf.items.len > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, h);
            }
        }
        if (buf.items.len == 0) return;
        config.headers = try buf.toOwnedSlice(allocator);
    }

    /// Flush in-flight telemetry and stop background exporters. Safe to call once.
    /// Called from App.run's normal teardown (after the http server thread has
    /// joined), so it must not block forever. We signal both processors to stop
    /// (cancel + await their export tasks) and stop log export, then return. We
    /// deliberately do NOT free the SDK structs/arenas here: a background export
    /// fiber may still be unwinding, and freeing its arena from this thread
    /// corrupts the heap. The OS reclaims all of it on process exit.
    pub fn shutdown(self: *Provider) void {
        if (!self.enabled) return;
        // Traces: stop the background export task and wait for it to exit (drains
        // any pending spans first). Do NOT forceFlush() concurrently with the
        // still-running task — it races on the shared exporter/queue.
        if (self.tracer_provider) |tp| tp.shutdown();
        // Logs: stop exporting *before* tearing down so any log emitted during
        // shutdown doesn't hit a half-torn-down provider.
        logs_export_enabled = false;
        active_log_logger = null;
        if (self.logger_provider) |lp| lp.shutdown() catch {};
    }

    /// Start a span parented to `parent` (or a fresh trace when null). The caller
    /// owns the returned span: end it with `endSpan` and free it with `deinit`.
    pub fn startSpan(
        self: *Provider,
        allocator: std.mem.Allocator,
        name: []const u8,
        parent: ?ActiveSpan,
        kind: SpanKind,
    ) !?Span {
        if (!self.enabled) return null;
        const tracer = self.tracer orelse return null;

        var parent_ctx: ?Context = null;
        var owned: ?Context = null;
        if (parent) |p| {
            owned = try parentContext(allocator, p);
            parent_ctx = owned;
        }
        const span = try tracer.startSpan(allocator, name, .{ .kind = kind, .parent_context = parent_ctx });
        if (owned) |*ctx| {
            trace_api.freeSerializedSpanContext(allocator, ctx.*);
            ctx.deinit();
        }
        return span;
    }

    /// Start a span parented to the currently-active span (see `pushSpan`/`currentSpan`).
    /// Returns null when disabled or when there is no active parent.
    pub fn startChildSpan(
        self: *Provider,
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: SpanKind,
    ) !?Span {
        if (!self.enabled) return null;
        const cur = currentSpan() orelse return null;
        return try self.startSpan(allocator, name, cur, kind);
    }

    /// End a span through the SDK (runs processors/exporters). Caller still owns
    /// the memory and must call `span.deinit()` afterwards.
    pub fn endSpan(self: *Provider, span: *Span) void {
        if (!self.enabled) return;
        const tracer = self.tracer orelse return;
        tracer.endSpan(span);
    }

    /// The SDK tracer instance (null when disabled).
    pub fn serverTracer(self: *Provider) ?*trace_api.TracerImpl {
        return self.tracer;
    }
};

/// Active OTel log bridge state, consumed by `logger.custom` (the global std.log
/// sink). Kept module-level because `custom` is a free function with no access to
/// the `Provider` instance.
var active_log_logger: ?*sdk.logs.Logger = null;
var logs_export_enabled: bool = false;
threadlocal var in_emit_log: bool = false;

/// True when the OTel log exporter is active (i.e. `otel_experimental=true`).
pub fn logsEnabled() bool {
    return logs_export_enabled;
}

/// Bridge a std.log record into OpenTelemetry logs. No-op when disabled or while
/// already inside an emit (recursion guard, since the SDK's own export errors
/// also flow through std.log). Correlates the record with the active span when
/// one exists.
pub fn emitLog(level: std.log.Level, body: []const u8) void {
    if (!logs_export_enabled) return;
    if (in_emit_log) return;
    in_emit_log = true;
    defer in_emit_log = false;

    const lg = active_log_logger orelse return;
    const severity: sdk.logs.Severity = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    const span_context = if (currentSpan()) |active|
        spanContextFromActive(std.heap.page_allocator, active)
    else
        null;
    lg.emit(severity, body, .{ .span_context = span_context });
}

/// Per-thread stack of active spans. The `tracz` middleware pushes the server
/// span on entry and pops it after the handler returns, so handlers/SQL/service
/// code can parent child spans to the current request via `Context.startChildSpan`.
const MAX_NESTED: usize = 16;
threadlocal var span_stack: [MAX_NESTED]ActiveSpan = undefined;
threadlocal var span_stack_len: usize = 0;

pub fn pushSpan(s: ActiveSpan) void {
    if (span_stack_len < MAX_NESTED) {
        span_stack[span_stack_len] = s;
        span_stack_len += 1;
    }
}

pub fn popSpan() void {
    if (span_stack_len > 0) span_stack_len -= 1;
}

pub fn currentSpan() ?ActiveSpan {
    if (span_stack_len == 0) return null;
    return span_stack[span_stack_len - 1];
}

pub fn activeFromSpan(sc: SpanContext) ActiveSpan {
    return .{
        .trace_id = sc.trace_id,
        .span_id = sc.span_id,
        .trace_flags = sc.trace_flags,
        .is_remote = sc.isRemote(),
    };
}

pub fn spanContextFromActive(allocator: std.mem.Allocator, a: ActiveSpan) SpanContext {
    return SpanContext.init(a.trace_id, a.span_id, a.trace_flags, trace_api.TraceState.init(allocator), a.is_remote);
}

fn parentContext(allocator: std.mem.Allocator, parent: ActiveSpan) !Context {
    const sc = SpanContext.init(
        parent.trace_id,
        parent.span_id,
        parent.trace_flags,
        trace_api.TraceState.init(allocator),
        parent.is_remote,
    );
    return try trace_api.insertSpanContext(allocator, sc);
}

/// Parse a W3C `traceparent` header (`00-<trace_id>-<span_id>-<flags>`).
/// Returns null on any malformed input.
pub fn parseTraceparent(header: []const u8) ?ActiveSpan {
    var it = std.mem.splitScalar(u8, header, '-');
    const ver = it.next() orelse return null;
    if (ver.len != 2) return null;
    const tid = it.next() orelse return null;
    if (tid.len != 32) return null;
    const sid = it.next() orelse return null;
    if (sid.len != 16) return null;
    const fl = it.next() orelse return null;
    if (fl.len != 2) return null;
    const trace_id = TraceID.fromHex(tid) catch return null;
    const span_id = SpanID.fromHex(sid) catch return null;
    const flags_val = std.fmt.parseInt(u8, fl, 16) catch return null;
    return ActiveSpan{
        .trace_id = trace_id,
        .span_id = span_id,
        .trace_flags = TraceFlags.init(flags_val),
        .is_remote = true,
    };
}

/// Format an `traceparent` header from a span context into `buf` (exactly 55 bytes).
/// `buf` must be at least 55 bytes; the returned slice is a subslice of `buf`.
pub fn formatTraceparent(buf: *[55]u8, sc: SpanContext) []const u8 {
    var tid: [32]u8 = undefined;
    var sid: [16]u8 = undefined;
    _ = sc.trace_id.toHex(&tid);
    _ = sc.span_id.toHex(&sid);
    return std.fmt.bufPrint(buf, "00-{s}-{s}-{x:0>2}", .{ tid, sid, sc.trace_flags.value }) catch buf[0..0];
}

/// Derive a `TraceID` from a 32-char hex string (e.g. the correlation id).
pub fn traceIDFromHex(hex: []const u8) ?TraceID {
    if (hex.len != 32) return null;
    return TraceID.fromHex(hex) catch null;
}

test "parseTraceparent round-trips with formatTraceparent" {
    const sc = SpanContext.init(
        TraceID.fromHex("0123456789abcdef0123456789abcdef") catch unreachable,
        SpanID.fromHex("0123456789abcdef") catch unreachable,
        TraceFlags.init(1),
        trace_api.TraceState.init(std.testing.allocator),
        true,
    );
    var buf: [55]u8 = undefined;
    const tp = formatTraceparent(&buf, sc);
    const parsed = parseTraceparent(tp) orelse unreachable;
    try std.testing.expectEqual(sc.trace_id.value, parsed.trace_id.value);
    try std.testing.expectEqual(sc.span_id.value, parsed.span_id.value);
    try std.testing.expectEqual(sc.trace_flags.value, parsed.trace_flags.value);
}

test "Provider is inert when disabled" {
    // No SDK objects are constructed; methods must be no-ops returning null.
    var p = Provider{ .enabled = false };
    try std.testing.expect((try p.startSpan(std.testing.allocator, "x", null, .Internal)) == null);
    p.shutdown();
}
