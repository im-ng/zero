const std = @import("std");
const linux = std.os.linux;

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
    sock: i32,
    thread: std.Thread,
    port: u16,
    stop_flag: *std.atomic.Value(bool),

    pub const Response = struct {
        status: u16 = 200,
        content_type: []const u8 = "application/json",
        body: []const u8,
    };

    fn newSocket() !i32 {
        const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (s > std.math.maxInt(i32)) return error.Unexpected;
        return @as(i32, @intCast(s));
    }

    fn check(rc: usize) !void {
        if (rc != 0) return error.Unexpected;
    }

    pub fn start(resp: Response) !FakeServer {
        const sock = try newSocket();
        errdefer _ = linux.close(sock);

        const yes: c_int = 1;
        _ = linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.REUSEADDR, &std.mem.toBytes(yes), @sizeOf(c_int));

        var sa: linux.sockaddr.in = .{
            .family = linux.AF.INET,
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
            .zero = [_]u8{0} ** 8,
        };
        try check(linux.bind(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa))));
        try check(linux.listen(sock, 1));

        var len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
        var got: linux.sockaddr.in = undefined;
        _ = linux.getsockname(sock, @ptrCast(&got), &len);
        const port = std.mem.bigToNative(u16, got.port);

        const flag = try std.heap.page_allocator.create(std.atomic.Value(bool));
        flag.* = .{ .raw = false };

        const t = try std.Thread.spawn(.{}, serve, .{ sock, resp, flag });
        return .{ .sock = sock, .thread = t, .port = port, .stop_flag = flag };
    }

    fn serve(sock: i32, resp: Response, stop_flag: *std.atomic.Value(bool)) void {
        var fds: [1]linux.pollfd = .{.{ .fd = sock, .events = linux.POLL.IN, .revents = 0 }};
        while (!stop_flag.load(.acquire)) {
            const rc = linux.poll(&fds, 1, 50);
            if (rc <= 0) continue;
            if (fds[0].revents & linux.POLL.IN == 0) continue;
            const conn_us = linux.accept(sock, null, null);
            if (conn_us > std.math.maxInt(i32)) continue;
            const conn: i32 = @intCast(conn_us);
            handle(conn, resp) catch {};
            _ = linux.close(conn);
        }
        _ = linux.close(sock);
    }

    fn handle(conn: i32, resp: Response) !void {
        var hdr: [8192]u8 = undefined;
        var hlen: usize = 0;
        var content_len: usize = 0;

        while (true) {
            const n = linux.read(conn, hdr[hlen..].ptr, hdr.len - hlen);
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
                if (std.ascii.indexOfIgnoreCase(l, "content-length")) |p| {
                    if (l.len > p + 15) {
                        const v = std.mem.trim(u8, l[p + 15 ..], " \r\n");
                        content_len = std.fmt.parseInt(usize, v, 10) catch 0;
                    }
                }
            }
            var total = hlen - (idx + 4);
            while (total < content_len) {
                const n = linux.read(conn, hdr[0..].ptr, hdr.len);
                if (n <= 0) break;
                total += @intCast(n);
            }
        }

        const out = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ resp.status, resp.content_type, resp.body.len, resp.body },
        );
        defer std.heap.page_allocator.free(out);

        var sent: usize = 0;
        while (sent < out.len) {
            const k = linux.write(conn, out[sent..].ptr, out.len - sent);
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
    defer _ = linux.close(sock);

    var sa: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    FakeServer.check(linux.connect(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa)))) catch @panic("connect");

    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var sent: usize = 0;
    while (sent < req.len) {
        const k = linux.write(sock, req[sent..].ptr, req.len - sent);
        if (k <= 0) break;
        sent += @intCast(k);
    }

    var got: [256]u8 = undefined;
    var n: usize = 0;
    while (n < got.len) {
        const k = linux.read(sock, got[n..].ptr, got.len - n);
        if (k <= 0) break;
        n += @intCast(k);
    }
    if (std.mem.indexOf(u8, got[0..n], "{\"ok\":true}") == null) {
        @panic("bad response");
    }
}
