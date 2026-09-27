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

pub fn create(allocator: std.mem.Allocator) !*rdz {
    const rz = try allocator.create(rdz);
    errdefer allocator.destroy(rz);
    return rz;
}

pub fn close(self: *Self) void {
    // Closes the underlying socket once; the Reader/Writer copies become unused.
    // The wrapper struct itself is freed by the caller.
    self.conn.close(utils.io);
}
