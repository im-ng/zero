const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;
const rdz = @This();
const Self = @This();

const rediz = root.rediz;
const SET = rediz.commands.strings.SET;
const OrErr = rediz.types.OrErr;
const Client = rediz.Client;

allocator: std.mem.Allocator,
log: *root.logger = undefined,
metricz: *root.metricz = undefined,
rbuf: [1024]u8 = undefined,
wbuf: [1024]u8 = undefined,
// Live connection. `reader`/`writer` each own a copy of the `TcpStream` returned
// by `addr.connect`, so the socket stays open for the app's lifetime and the
// `rediz.Client` (which borrows `&reader.interface`/`&writer.interface`) never
// points at freed memory. They must live in this heap struct, not on the stack
// of `wireRedis` — a stack-local copy would be reclaimed before first use and the
// client would write through a dangling vtable (general-protection fault).
// `conn` is kept so teardown can close the underlying socket (the Reader/Writer
// types expose no `close` of their own).
conn: std.Io.net.Stream = undefined,
reader: std.Io.net.Stream.Reader = undefined,
writer: std.Io.net.Stream.Writer = undefined,
// Canonical Redis client. All consumers (KV, rate limiter, health probe) send
// through this and serialize on `mu` so concurrent commands can't interleave
// RESP frames on the single shared socket
client: rediz.Client = undefined,
mu: std.Io.Mutex = .init,
// Reconnect parameters captured at startup so a dead socket can be rebuilt
// in place (the shared `reader`/`writer`/`client` stay at the same addresses,
// so every consumer heals without re-pointing). `addr` is the resolved
// endpoint; `pass` points at config-owned memory (app-lifetime stable).
addr: std.Io.net.IpAddress = undefined,
pass: []const u8 = "",

pub fn create(allocator: std.mem.Allocator) !*rdz {
    const rz = try allocator.create(rdz);
    errdefer allocator.destroy(rz);
    rz.client = undefined;
    return rz;
}

/// Re-establish the shared socket after an outage. Reuses the same heap
/// `reader`/`writer`/`client` slots so `container.redis` (which borrows their
/// `.interface` addresses) is healed transparently. No-op-safe: a failed
/// reconnect leaves the caller to report the outage.
pub fn reconnect(self: *Self) !void {
    self.mu.lock(utils.io) catch {};
    defer self.mu.unlock(utils.io);
    // Best-effort tear-down of the dead socket; ignore errors (already broken).
    self.conn.close(utils.io);
    const connection = self.addr.connect(utils.io, .{ .mode = .stream }) catch return error.RedisConnectFailed;
    self.conn = connection;
    self.reader = connection.reader(utils.io, &self.rbuf);
    self.writer = connection.writer(utils.io, &self.wbuf);
    self.client = try Client.init(utils.io, &self.reader.interface, &self.writer.interface, .{ .user = null, .pass = self.pass });
    const pong = self.client.sendAlloc([]u8, self.allocator, .{"ping"}) catch return error.RedisConnectFailed;
    self.allocator.free(pong);
}

pub fn close(self: *Self) void {
    // Closes the underlying socket once; the Reader/Writer copies become unused.
    // The wrapper struct itself is freed by the caller.
    self.conn.close(utils.io);
}
