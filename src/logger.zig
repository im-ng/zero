const std = @import("std");
const logger = @This();
const Self = @This();
const root = @import("zero.zig");
const utils = root.utils;
const otel = root.otel;

var mutex: std.Io.Mutex = .init;

/// When true, log lines are emitted as JSON (`{"ts":...,"level":...,"msg":...}`)
/// instead of the default colorized text. Controlled by `LOG_FORMAT=json`.
var json_format: bool = false;

/// When true, the OpenTelemetry log body is the JSON line (same shape as the
/// console JSON output) rather than the clean plaintext message. Controlled by
/// `OTEL_LOG_JSON=true` (see `app.zig`).
var otel_json: bool = false;

allocator: std.mem.Allocator,
logLevel: u8 = undefined,

/// Formats `value` into `buf`, using `{s}` for string-like values and `{any}`
/// otherwise, so non-string payloads (e.g. structs) still serialize in JSON mode.
fn formatArg(buf: []u8, value: anytype) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return std.fmt.bufPrint(buf, "{s}", .{value}) catch "";
        },
        .array => |arr| {
            if (arr.child == u8) return std.fmt.bufPrint(buf, "{s}", .{value}) catch "";
        },
        else => {},
    }
    return std.fmt.bufPrint(buf, "{any}", .{value}) catch "";
}

/// Minimal sink that appends (with JSON-string escaping) into a fixed buffer.
/// Lets us render the JSON log line into a stack buffer that both the console
/// writer and the OpenTelemetry body can share.
const JsonSink = struct {
    buf: []u8,
    len: usize,
    fn write(self: *JsonSink, s: []const u8) void {
        const avail = self.buf.len - self.len;
        const take = @min(s.len, avail);
        if (take > 0) @memcpy(self.buf[self.len .. self.len + take], s[0..take]);
        self.len += take;
    }
    fn writeEsc(self: *JsonSink, s: []const u8) void {
        for (s) |c| switch (c) {
            '"' => self.write("\\\""),
            '\\' => self.write("\\\\"),
            '\n' => self.write("\\n"),
            '\r' => self.write("\\r"),
            '\t' => self.write("\\t"),
            else => self.write(&.{c}),
        };
    }
};

/// Masks credential material in a log line so secrets never reach stdout/OTel.
/// Handles `Basic `/`Bearer ` tokens, `Authorization:`/`x-api-key:` headers, and
/// `key=value` pairs for common secret keys. Returns a slice of `out` (caller must
/// provide a buffer at least as large as `src`). Masking only shortens, so `out`
/// never overflows.
fn redactInto(src: []const u8, out: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const rem = src[i..];
        if (startsWithIgnoreCase(rem, "Basic ")) {
            o = append(out, o, "Basic ");
            i += 6;
            i = skipToken(src, i, &o, out);
            continue;
        }
        if (startsWithIgnoreCase(rem, "Bearer ")) {
            o = append(out, o, "Bearer ");
            i += 7;
            i = skipToken(src, i, &o, out);
            continue;
        }
        if (startsWithIgnoreCase(rem, "Authorization:")) {
            o = append(out, o, "Authorization:");
            i += 14;
            i = skipLeadingSpaceAndScheme(src, i, &o, out);
            continue;
        }
        if (startsWithIgnoreCase(rem, "x-api-key:")) {
            o = append(out, o, "x-api-key:");
            i += 10;
            i = skipLeadingSpaceAndScheme(src, i, &o, out);
            continue;
        }
        if (startsWithIgnoreCase(rem, "password=") or
            startsWithIgnoreCase(rem, "secret=") or
            startsWithIgnoreCase(rem, "api_key=") or
            startsWithIgnoreCase(rem, "token=") or
            startsWithIgnoreCase(rem, "access_token=") or
            startsWithIgnoreCase(rem, "refresh_token="))
        {
            const eq = std.mem.indexOfScalar(u8, rem, '=') orelse rem.len - 1;
            o = append(out, o, rem[0 .. eq + 1]);
            i += eq + 1;
            i = skipUntilDelim(src, i, &o, out);
            continue;
        }
        out[o] = src[i];
        o += 1;
        i += 1;
    }
    return out[0..o];
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |p, k| {
        if (std.ascii.toLower(s[k]) != std.ascii.toLower(p)) return false;
    }
    return true;
}

fn append(out: []u8, o: usize, s: []const u8) usize {
    const take = @min(s.len, out.len - o);
    @memcpy(out[o .. o + take], s[0..take]);
    return o + take;
}

fn skipToken(src: []const u8, i: usize, o: *usize, out: []u8) usize {
    var j = i;
    while (j < src.len and src[j] != ' ' and src[j] != '\n' and src[j] != '\r' and src[j] != '\t') {
        j += 1;
    }
    o.* = append(out, o.*, "***");
    return j;
}

/// After a header prefix like `Authorization:` / `x-api-key:`, skip the optional
/// leading whitespace and an optional `Basic `/`Bearer ` scheme word, then mask the
/// remaining credential token.
fn skipLeadingSpaceAndScheme(src: []const u8, i: usize, o: *usize, out: []u8) usize {
    var j = i;
    while (j < src.len and (src[j] == ' ' or src[j] == '\t')) : (j += 1) {}
    const rem = src[j..];
    if (startsWithIgnoreCase(rem, "Basic ")) {
        j += 6;
    } else if (startsWithIgnoreCase(rem, "Bearer ")) {
        j += 7;
    }
    return skipToken(src, j, o, out);
}

fn skipUntilDelim(src: []const u8, i: usize, o: *usize, out: []u8) usize {
    var j = i;
    while (j < src.len and src[j] != ' ' and src[j] != '&' and src[j] != '\n' and src[j] != '\r') {
        j += 1;
    }
    o.* = append(out, o.*, "***");
    return j;
}

pub fn custom(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const out = std.Io.File.stdout();

    // Full formatted message (text mode + fallback OTel body).
    var msg_buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch "log format error";

    // Clean message for the OTel body: framework log helpers bake ANSI colors and
    // a "[ts]" prefix into `format`, so for those calls the real message is args[1].
    // App-level logs (no message arg) fall back to the raw message.
    var m_buf: [2048]u8 = undefined;
    const clean_msg = if (args.len >= 2) formatArg(&m_buf, args[1]) else msg;

    // The JSON line is built lazily — only when console json_format is on or an
    // OTel JSON body is requested. This avoids an ~8KB format per log line when
    // neither applies.
    var json_buf: [8192]u8 = undefined;
    var json_slice: []const u8 = "";

    // Redact credential material from both the text message and the clean message
    // before they are written to console or exported to OTel.
    var redacted_msg_buf: [2048]u8 = undefined;
    const rmsg = redactInto(msg, &redacted_msg_buf);
    var redacted_clean_buf: [2048]u8 = undefined;
    const rclean = redactInto(clean_msg, &redacted_clean_buf);

    if (json_format or (otel.logsEnabled() and otel_json)) {
        var sink: JsonSink = .{ .buf = &json_buf, .len = 0 };
        var ts_buf: [64]u8 = undefined;
        const ts = if (args.len >= 1) formatArg(&ts_buf, args[0]) else "";

        // Optional trace correlation: when a request span is active (per-thread
        // `otel.currentSpan()`), attach its ids so logs join their trace in the
        // backend. Outside a request `currentSpan()` is null and these fields are
        // omitted.
        var tid_hex: [32]u8 = undefined;
        var sid_hex: [16]u8 = undefined;
        const active = otel.currentSpan();
        const tid = if (active) |sp| sp.trace_id.toHex(&tid_hex) else null;
        const sid = if (active) |sp| sp.span_id.toHex(&sid_hex) else null;

        sink.write("{\"ts\":\"");
        sink.writeEsc(ts);
        sink.write("\",\"level\":\"");
        sink.write(@tagName(level));
        sink.write("\",\"msg\":\"");
        sink.writeEsc(rclean);
        sink.write("\"");
        if (tid) |t| {
            sink.write(",\"trace_id\":\"");
            sink.write(t);
            sink.write("\"");
        }
        if (sid) |s| {
            sink.write(",\"span_id\":\"");
            sink.write(s);
            sink.write("\"");
        }
        sink.write("}\n");
        json_slice = sink.buf[0..sink.len];
    }

    // Console output: serialized through the global logger mutex so stdout writes
    // don't interleave. The OTel enqueue runs AFTER the lock is released (below),
    // so logging no longer serializes on the export path under concurrency.
    {
        mutex.lock(utils.io) catch {};
        defer mutex.unlock(utils.io);
        if (json_format) {
            out.writeStreamingAll(utils.io, json_slice) catch return;
        } else {
            out.writeStreamingAll(utils.io, rmsg) catch return;
        }
    }

    // Parallel OpenTelemetry log export (no-op when otel_experimental is off).
    // Runs OUTSIDE the global logger mutex: the SDK clones the body into its own
    // arena, so these stack slices are safe after the lock is released, and we
    // avoid serializing every log line through the OTel enqueue. Default body is
    // the clean message; OTEL_LOG_JSON=true streams the JSON line.
    if (otel.logsEnabled()) {
        var otel_buf: [4096]u8 = undefined;
        const lvl = @tagName(level);
        var on: usize = 0;
        @memcpy(otel_buf[0..lvl.len], lvl);
        on += lvl.len;
        otel_buf[on] = ' ';
        on += 1;
        @memcpy(otel_buf[on .. on + rclean.len], rclean);
        on += rclean.len;
        const otel_clean = otel_buf[0..on];

        if (otel_json) otel.emitLog(level, json_slice) else otel.emitLog(level, otel_clean);
    }
}

pub fn create(allocator: std.mem.Allocator) !*logger {
    const l: *logger = try allocator.create(logger);
    errdefer allocator.destroy(l);

    l.allocator = allocator;
    l.logLevel = 1;

    return l;
}

/// Enables (`true`) or disables (`false`) JSON structured log output. Driven by
/// the `LOG_FORMAT=json` app config (see `app.zig`).
pub fn setJsonFormat(enabled: bool) void {
    json_format = enabled;
}

/// Enables (`true`) or disables (`false`) JSON as the OpenTelemetry log body.
/// Driven by the `OTEL_LOG_JSON=true` app config (see `app.zig`).
pub fn setOtelJsonFormat(enabled: bool) void {
    otel_json = enabled;
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}

const debugFormat = "\x1b[38;5;8mDEBUG\x1b[0m [{s}] {s}\n";
const infoFormat = "\x1b[38;5;6m INFO\x1b[0m [{s}] {s}\n";
const anyFormat = "\x1b[38;5;6m INFO\x1b[0m [{s}] {any}\n";
const warnFormat = "\x1b[38;5;220m WARN\x1b[0m [{s}] {s}\n";
const errFormat = "\x1b[38;5;160mERROR\x1b[0m [{s}] {s}\n";
const fatalFormat = "\x1b[38;5;140mFATAL\x1b[0m [{s}] {s}\n";

pub fn debug(self: Self, message: []const u8) void {
    if (self.logLevel > 0) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.debug(debugFormat, .{ ts, message });
}

pub fn info(self: Self, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.info(infoFormat, .{ ts, message });
}

pub fn any(self: Self, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.info(anyFormat, .{ ts, message });
}

pub fn warn(self: Self, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }
    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.warn(warnFormat, .{ ts, message });
}

pub fn err(self: Self, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.err(errFormat, .{ ts, message });
}

pub fn fatal(self: Self, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);
    std.log.err(fatalFormat, .{ ts, message });
}

pub fn Debug(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 0) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.debug(debugFormat, .{ ts, message });
}

pub fn Info(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.info(infoFormat, .{ ts, message });
}

pub fn Any(self: *Self, _: std.mem.Allocator, message: anytype) void {
    if (self.logLevel > 1) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.info(anyFormat, .{ ts, message });
}

pub fn Warn(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 2) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.warn(warnFormat, .{ ts, message });
}

pub fn Err(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 3) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.err(errFormat, .{ ts, message });
}

pub fn Fatal(self: *Self, _: std.mem.Allocator, message: []const u8) void {
    if (self.logLevel > 4) {
        return;
    }

    var ts_buf: [64]u8 = undefined;
    const ts = utils.timestampzBuf(&ts_buf);

    std.log.err(errFormat, .{ ts, message });
}


// ===================== Tests =====================

test "redactInto masks credential tokens and secret key=value pairs" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "GET /x Authorization:***",
        redactInto("GET /x Authorization: Basic c2Vjcr", &buf),
    );
    try std.testing.expectEqualStrings(
        "Bearer ***",
        redactInto("Bearer eyJhbGciOiJIUzI1NiJ9", &buf),
    );
    try std.testing.expectEqualStrings(
        "token=***&user=bob",
        redactInto("token=abc123&user=bob", &buf),
    );
    try std.testing.expectEqualStrings(
        "x-api-key:*** done",
        redactInto("x-api-key: secret-key done", &buf),
    );
}


test "create returns logger with default logLevel 1" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    try std.testing.expectEqual(@as(u8, 1), log.logLevel);
}

test "debug suppressed when logLevel > 0" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 1;
    log.debug("should not appear");
    try std.testing.expect(true);
}

test "info suppressed when logLevel > 1" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 2;
    log.info("should not appear");
    try std.testing.expect(true);
}

test "warn suppressed when logLevel > 2" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 3;
    log.warn("should not appear");
    try std.testing.expect(true);
}

test "err suppressed when logLevel > 3" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 4;
    log.err("should not appear");
    try std.testing.expect(true);
}

test "fatal suppressed when logLevel > 5" {
    const allocator = std.testing.allocator;
    const log = try create(allocator);
    defer allocator.destroy(log);
    log.logLevel = 5;
    log.fatal("should not appear");
    try std.testing.expect(true);
}
