const std = @import("std");
const posix = std.posix;
// The framework links libc on every supported target, so `system` resolves to
// `std.c` on both Linux and macOS. `posix` supplies the portable types and
// constants; `system` supplies the socket calls that Zig 0.17 does not wrap.
const c = std.posix.system;

/// A minimal in-process HTTP/1.1 server used to unit-test the HTTP-backed data
/// sources (ClickHouse, Couchbase) without an external service. It accepts
/// connections on a loop using plain blocking POSIX sockets (the same approach
/// `httpz` uses for its in-test server), reads each request fully, and replies
/// with a canned response — so the client code's real network path is exercised
/// end to end. Because it is just blocking sockets on its own OS thread, it does
/// not depend on the test's `std.Io` event loop and cannot deadlock against it.
///
/// The accept loop is interruptible via a stop flag checked after each 50ms
/// `poll` timeout (closing the listening socket from the test thread does not
/// wake `accept` under the test runtime's io_uring, so we avoid that pattern).
pub const FakeServer = struct {
    sock: posix.socket_t,
    thread: std.Thread,
    port: u16,
    stop_flag: *std.atomic.Value(bool),

    pub const Response = struct {
        status: u16 = 200,
        content_type: []const u8 = "application/json",
        body: []const u8,
        /// Optional pause before the response is written. Used to test client
        /// request deadlines against a server that accepts but stalls.
        delay_ms: u64 = 0,
    };

    fn newSocket() !posix.socket_t {
        // CLOEXEC is deliberately omitted: Darwin only offers a Zig shim bit
        // that libc does not understand, and these sockets are short-lived.
        const s = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (s < 0) return error.Unexpected;
        return s;
    }

    fn check(rc: c_int) !void {
        if (rc != 0) return error.Unexpected;
    }

    pub fn start(resp: Response) !FakeServer {
        const sock = try newSocket();
        errdefer _ = c.close(sock);

        const yes: c_int = 1;
        posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&yes),
        ) catch {};

        // `len` has a default on Darwin and does not exist on Linux, so omitting
        // it keeps the same initializer valid on both.
        var sa: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
            .zero = @splat(0),
        };
        try check(c.bind(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa))));
        try check(c.listen(sock, 1));

        var len: posix.socklen_t = @sizeOf(@TypeOf(sa));
        var got: posix.sockaddr.in = undefined;
        try check(c.getsockname(sock, @ptrCast(&got), &len));
        const port = std.mem.bigToNative(u16, got.port);

        const flag = try std.heap.page_allocator.create(std.atomic.Value(bool));
        flag.* = .{ .raw = false };

        const t = try std.Thread.spawn(.{}, serve, .{ sock, resp, flag });
        return .{ .sock = sock, .thread = t, .port = port, .stop_flag = flag };
    }

    fn serve(sock: posix.socket_t, resp: Response, stop_flag: *std.atomic.Value(bool)) void {
        var fds: [1]posix.pollfd = .{.{ .fd = sock, .events = posix.POLL.IN, .revents = 0 }};
        while (!stop_flag.load(.acquire)) {
            const rc = posix.poll(&fds, 50) catch continue;
            if (rc <= 0) continue;
            if (fds[0].revents & posix.POLL.IN == 0) continue;
            const conn = c.accept(sock, null, null);
            if (conn < 0) continue;
            handle(conn, resp) catch {};
            _ = c.close(conn);
        }
        _ = c.close(sock);
    }

    fn handle(conn: posix.socket_t, resp: Response) !void {
        var hdr: [8192]u8 = undefined;
        var hlen: usize = 0;
        var content_len: usize = 0;

        while (true) {
            const n = c.read(conn, hdr[hlen..].ptr, hdr.len - hlen);
            if (n <= 0) break;
            hlen += @intCast(n);
            if (hlen >= 4 and std.mem.indexOf(u8, hdr[0..hlen], "\r\n\r\n") != null) break;
            if (hlen == hdr.len) break;
        }
        if (std.mem.indexOf(u8, hdr[0..hlen], "\r\n\r\n")) |idx| {
            const head = hdr[0..idx];
            var it = std.mem.splitScalar(u8, head, '\n');
            while (it.next()) |line| {
                const l = std.mem.trim(u8, line, "\r");
                if (std.ascii.findIgnoreCase(l, "content-length")) |p| {
                    if (l.len > p + 15) {
                        const v = std.mem.trim(u8, l[p + 15 ..], " \r\n");
                        content_len = std.fmt.parseInt(usize, v, 10) catch 0;
                    }
                }
            }
            var total = hlen - (idx + 4);
            while (total < content_len) {
                const n = c.read(conn, hdr[0..].ptr, hdr.len);
                if (n <= 0) break;
                total += @intCast(n);
            }
        }

        if (resp.delay_ms > 0) {
            // Use an OS-level sleep, not std.Io.sleep: the test Io may use a
            // virtual clock under some runners, which would skip the delay.
            var ts: posix.timespec = undefined;
            ts.sec = @intCast(resp.delay_ms / 1000);
            ts.nsec = @intCast((resp.delay_ms % 1000) * 1_000_000);
            _ = c.nanosleep(&ts, null);
        }

        const out = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ resp.status, resp.content_type, resp.body.len, resp.body },
        );
        defer std.heap.page_allocator.free(out);

        var sent: usize = 0;
        while (sent < out.len) {
            const k = c.write(conn, out[sent..].ptr, out.len - sent);
            if (k <= 0) break;
            sent += @intCast(k);
        }
    }

    pub fn stop(self: *FakeServer) void {
        self.stop_flag.store(true, .release);
        self.thread.join();
        std.heap.page_allocator.destroy(self.stop_flag);
    }
};

test "FakeServer answers an HTTP request" {
    var fs = try FakeServer.start(.{ .body = "{\"ok\":true}" });
    defer fs.stop();
    const t = try std.Thread.spawn(.{}, clientRun, .{fs.port});
    t.join();
}

fn clientRun(port: u16) void {
    const sock = FakeServer.newSocket() catch @panic("socket");
    defer _ = c.close(sock);

    var sa: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = @splat(0),
    };
    FakeServer.check(c.connect(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa)))) catch @panic("connect");

    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var sent: usize = 0;
    while (sent < req.len) {
        const k = c.write(sock, req[sent..].ptr, req.len - sent);
        if (k <= 0) break;
        sent += @intCast(k);
    }

    var got: [256]u8 = undefined;
    var n: usize = 0;
    while (n < got.len) {
        const k = c.read(sock, got[n..].ptr, got.len - n);
        if (k <= 0) break;
        n += @intCast(k);
    }
    if (std.mem.indexOf(u8, got[0..n], "{\"ok\":true}") == null) {
        @panic("bad response");
    }
}
