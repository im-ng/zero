const std = @import("std");
const root = @import("zero.zig");
const Context = @import("context.zig").Context;
const ws = root.httpz.websocket;

const Io = std.Io;
const client = root.client;
const circuit_breaker = root.circuit_breaker;

/// Callback for each inbound websocket frame. `frame` is valid only for the
/// duration of the call. `userdata` is the pointer passed to `connect`.
pub const MessageFn = *const fn (*Context, []const u8, ?*anyopaque) anyerror!void;

/// Callback fired once after the handshake succeeds, used to send an initial
/// subscribe/login frame. `userdata` is the pointer passed to `connect`.
pub const OpenFn = *const fn (*Client, ?*anyopaque) anyerror!void;

/// Options for `App.addWebsocketClient`. Mirrors the shape of the outbound HTTP
/// service options (`ServiceOptions`): a name-keyed registration plus connection
/// config, resolved outbound auth, and the app-supplied message/open handlers.
pub const Options = struct {
    headers: ?[]const u8 = null,
    /// Outbound auth attached to the handshake. Resolves from `SERVICE_<NAME>_*`
    /// env (like `addHttpService`) when left null, or set explicitly here.
    auth: ?client.OutboundAuth = null,
    /// Circuit breaker guarding the downstream (open = stop reconnecting).
    circuitBreaker: ?circuit_breaker.CircuitBreakerConfig = null,
    on_message: MessageFn,
    on_open: ?OpenFn = null,
    userdata: ?*anyopaque = null,
};

/// A long-lived outbound websocket connection. Owns its own background thread,
/// reconnects with backoff until `stop`/`deinit` is called, and dispatches each
/// frame to the supplied callbacks with a datasource-wired `Context` (built via
/// `Context.initCli`, so the HTTP `response` is left undefined — coin's sinks
/// never touch it). Outbound auth is attached to the handshake and a circuit
/// breaker gates the (re)connection attempts.
pub const Client = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls: bool,
    path: []const u8,
    headers: ?[]const u8,
    on_message: MessageFn,
    on_open: ?OpenFn,
    userdata: ?*anyopaque,
    /// Resolved outbound auth, attached to the handshake as a header.
    auth: ?client.OutboundAuth = null,
    /// Circuit breaker guarding the downstream; when open, reconnection pauses.
    breaker: ?circuit_breaker.CircuitBreaker = null,
    shutdown: std.atomic.Value(bool),
    thread: std.Thread,
    conn: ?ws.Client,
    /// Heap-allocated (mirrors the framework's `Context.deinit`, which frees the
    /// struct itself); `deinit` releases it via `ctx.deinit()`.
    ctx: *Context,

    /// Send a text frame to the server (e.g. a subscribe message). No-op if the
    /// connection is not currently established.
    pub fn sendText(self: *Client, data: []const u8) !void {
        if (self.conn) |*c| {
            const buf = try self.allocator.dupe(u8, data);
            defer self.allocator.free(buf);
            try c.writeText(buf);
        }
    }

    /// Send a binary frame to the server.
    pub fn sendBin(self: *Client, data: []const u8) !void {
        if (self.conn) |*c| {
            const buf = try self.allocator.dupe(u8, data);
            defer self.allocator.free(buf);
            try c.writeBin(buf);
        }
    }

    /// Signal the background thread to stop and join it.
    pub fn stop(self: *Client) void {
        self.shutdown.store(true, .monotonic);
        self.thread.join();
    }

    /// Signal the background thread to stop, join it, and free the client plus
    /// its datasource-wired `Context` and the duped URL parts. Safe to call
    /// exactly once.
    pub fn deinit(self: *Client) void {
        self.stop();
        self.ctx.deinit();
        if (self.headers) |h| {
            self.allocator.free(h);
        }
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn run(self: *Client) void {
        var backoff: u64 = 0;
        while (!self.shutdown.load(.monotonic)) {
            // Circuit breaker gates the (re)connection attempt. When open we
            // back off instead of hammering a downstream that is flapping.
            if (self.breaker) |*b| {
                b.before() catch {
                    std.Io.sleep(self.ctx.io, std.Io.Duration.fromSeconds(@intCast(nextBackoff(backoff))), .awake) catch {};
                    backoff = nextBackoff(backoff);
                    continue;
                };
            }

            if (backoff > 0) {
                // Best-effort backoff sleep; if it fails we simply retry sooner.
                std.Io.sleep(self.ctx.io, std.Io.Duration.fromSeconds(@intCast(backoff)), .awake) catch {};
                backoff = 0;
            }

            // Build handshake headers: user-supplied plus resolved outbound auth.
            // HTTP/1.1 requires CRLF line endings for the handshake, so always
            // use `\r\n` and normalize any bare LF the caller used in `headers`.
            const term = "\r\n";
            var hdr = std.ArrayList(u8).empty;
            if (self.headers) |h| {
                var it = std.mem.splitScalar(u8, h, '\n');
                while (it.next()) |raw| {
                    const line = std.mem.trimEnd(u8, raw, "\r");
                    if (line.len == 0) continue;
                    hdr.appendSlice(self.allocator, line) catch return;
                    hdr.appendSlice(self.allocator, term) catch return;
                }
            }
            if (self.auth) |a| {
                if (a.mode == .oauth) {
                    const cfg = a.oauth orelse {
                        backoff = nextBackoff(backoff);
                        continue;
                    };
                    const token = root.gcp_oauth.fetchToken(
                        self.allocator,
                        self.ctx.io,
                        cfg.tokenUrl,
                        cfg.clientId,
                        cfg.clientSecret,
                        cfg.scope orelse "",
                    ) catch {
                        if (self.breaker) |*b| b.recordFailure();
                        backoff = nextBackoff(backoff);
                        continue;
                    };
                    defer self.allocator.free(token.access_token);

                    hdr.appendSlice(self.allocator, "authorization: Bearer ") catch return;
                    hdr.appendSlice(self.allocator, token.access_token) catch return;
                    hdr.appendSlice(self.allocator, term) catch return;
                } else if (a.buildHeader(self.allocator) catch null) |hpair| {
                    defer self.allocator.free(hpair.value);
                    hdr.appendSlice(self.allocator, hpair.name) catch return;
                    hdr.appendSlice(self.allocator, ": ") catch return;
                    hdr.appendSlice(self.allocator, hpair.value) catch return;
                    hdr.appendSlice(self.allocator, term) catch return;
                }
            }

            // RFC 6455 requires a `Host` header; the websocket library does not
            // add one, and servers like Bybit reject the handshake without it
            // (returning a non-101 → `InvalidHandshakeResponse`). Send it always.
            hdr.appendSlice(self.allocator, "host: ") catch return;
            hdr.appendSlice(self.allocator, self.host) catch return;
            hdr.appendSlice(self.allocator, term) catch return;

            const headers_arg = if (hdr.items.len > 0) hdr.items else null;
            defer hdr.deinit(self.allocator);

            var conn = ws.Client.init(self.ctx.io, self.allocator, .{
                .host = self.host,
                .port = self.port,
                .tls = self.tls,
                .ca_bundle = null,
            }) catch {
                if (self.breaker) |*b| b.recordFailure();
                backoff = nextBackoff(backoff);
                continue;
            };
            conn.handshake(self.path, .{ .headers = headers_arg }) catch |e| {
                conn.deinit();
                // Surface handshake failures so a dead/unreachable endpoint is
                // visible instead of silently retrying forever.
                std.log.err("websocket handshake to {s}{s} failed: {s}", .{ self.host, self.path, @errorName(e) });
                if (self.breaker) |*b| b.recordFailure();
                backoff = nextBackoff(backoff);
                continue;
            };

            if (self.breaker) |*b| b.recordSuccess();

            std.log.info("websocket connected to {s}{s}", .{ self.host, self.path });
            self.conn = conn;
            if (self.on_open) |o| {
                // A failed subscribe/login should not tear down the live connection.
                o(self, self.userdata) catch |e| std.log.warn("websocket on_open failed: {}", .{e});
            }

            const c = &self.conn.?;
            // Best-effort read timeout; a failure here only means reads block longer.
            c.readTimeout(1000) catch {};
            while (!self.shutdown.load(.monotonic)) {
                const maybe = c.read() catch break;
                const msg = maybe orelse continue;
                switch (msg.type) {
                    .text, .binary => {
                        self.on_message(self.ctx, msg.data, self.userdata) catch |e| {
                            std.log.warn("websocket on_message failed: {}", .{e});
                        };
                    },
                    .ping => {
                        const buf = self.allocator.dupe(u8, msg.data) catch return;
                        defer self.allocator.free(buf);
                        // Best-effort pong reply; a failure means the socket is likely gone.
                        c.writePong(buf) catch {};
                    },
                    .pong => {},
                    .close => break,
                }
                c.done(msg);
            }

            if (self.conn) |*cc| {
                cc.deinit();
            }
            self.conn = null;
            // A dropped/closed connection counts as a failure for the breaker.
            if (self.breaker) |*b| b.recordFailure();
            if (self.shutdown.load(.monotonic)) break;
            backoff = nextBackoff(backoff);
        }
    }
};

/// Parse a `ws://`/`wss://` URL and open a background connection that reconnects
/// until `stop`/`deinit` is called. Spawns its own thread. The returned client is
/// owned by the caller (in the framework, by the container) and must be released
/// with `Client.deinit`.
pub fn connect(
    allocator: std.mem.Allocator,
    container: *root.container,
    url: []const u8,
    headers: ?[]const u8,
    on_message: MessageFn,
    on_open: ?OpenFn,
    userdata: ?*anyopaque,
    auth: ?client.OutboundAuth,
    cb: ?circuit_breaker.CircuitBreakerConfig,
) !*Client {
    const parsed = try parseUrl(url);
    const host = try allocator.dupe(u8, parsed.host);
    const path = try allocator.dupe(u8, parsed.path);
    const hdrs = if (headers) |h| try allocator.dupe(u8, h) else null;
    errdefer {
        allocator.free(host);
        allocator.free(path);
        if (hdrs) |h| {
            allocator.free(h);
        }
    }

    var self = try allocator.create(Client);
    self.* = .{
        .allocator = allocator,
        .host = host,
        .port = parsed.port,
        .tls = parsed.tls,
        .path = path,
        .headers = hdrs,
        .on_message = on_message,
        .on_open = on_open,
        .userdata = userdata,
        .auth = auth,
        .breaker = if (cb) |c| circuit_breaker.CircuitBreaker.init(c) else null,
        .shutdown = std.atomic.Value(bool).init(false),
        .thread = undefined,
        .conn = null,
        .ctx = undefined,
    };

    const ctx_ptr = allocator.create(Context) catch |e| {
        allocator.destroy(self);
        return e;
    };
    ctx_ptr.* = Context.initCli(allocator, container) catch |e| {
        allocator.destroy(ctx_ptr);
        allocator.destroy(self);
        return e;
    };
    self.ctx = ctx_ptr;

    self.thread = std.Thread.spawn(.{}, Client.run, .{self}) catch |e| {
        self.ctx.deinit();
        allocator.destroy(self);
        return e;
    };
    return self;
}

fn nextBackoff(current: u64) u64 {
    if (current == 0) return 1;
    if (current < 30) return current * 2;
    return 30;
}

const UrlParts = struct { host: []const u8, port: u16, tls: bool, path: []const u8 };

fn parseUrl(url: []const u8) !UrlParts {
    var rest = url;
    var tls = false;
    if (std.mem.startsWith(u8, rest, "wss://")) {
        tls = true;
        rest = rest[6..];
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest[5..];
    } else {
        return error.InvalidWebSocketUrl;
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var port: u16 = if (tls) 443 else 80;
    var host = authority;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseUnsigned(u16, authority[colon + 1 ..], 10) catch return error.InvalidWebSocketUrl;
    }
    return .{ .host = host, .port = port, .tls = tls, .path = path };
}
