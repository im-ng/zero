const std = @import("std");
const httpz = @import("httpz");
const root = @import("../zero.zig");
const utils = root.utils;

pub const rateLimiter = @This();

pub const KeyMode = enum {
    ip,
    header,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    limit: u64 = 100,
    window_ms: i64 = 60_000,
    key_mode: KeyMode = .ip,
    header_name: []const u8 = "X-Forwarded-For",
};

const Window = struct {
    count: u64,
    reset_at: i128,
};

const max_entries = 1_000_000;

allocator: std.mem.Allocator,
enabled: bool,
limit: u64,
window_ns: i128,
key_mode: KeyMode,
header_name: []const u8,
mu: std.Io.Mutex,
buckets: std.AutoHashMap(u64, Window),

pub fn init(c: Config) !rateLimiter {
    return .{
        .allocator = c.allocator,
        .enabled = c.enabled,
        .limit = c.limit,
        .window_ns = @as(i128, c.window_ms) * 1_000_000,
        .key_mode = c.key_mode,
        .header_name = c.header_name,
        .mu = .init,
        .buckets = std.AutoHashMap(u64, Window).init(c.allocator),
    };
}

pub fn execute(self: *const rateLimiter, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (!self.enabled) return executor.next();
    if (std.mem.startsWith(u8, req.url.path, "/.well-known")) return executor.next();

    const key = self.keyFor(req) orelse return executor.next();
    const now = utils.nowMonotonic().nanoseconds;

    self.mu.lockUncancelable(utils.io);
    if (self.buckets.count >= max_entries) {
        self.mu.unlock(utils.io);
        return executor.next();
    }

    const gop = self.buckets.getOrPut(key) catch {
        self.mu.unlock(utils.io);
        return executor.next();
    };
    if (!gop.found_existing or (now - gop.value_ptr.*.reset_at) >= self.window_ns) {
        gop.value_ptr.* = .{ .count = 0, .reset_at = now };
    }
    gop.value_ptr.*.count += 1;
    const over = gop.value_ptr.*.count > self.limit;
    self.mu.unlock(utils.io);

    if (over) {
        res.setStatus(std.http.Status.too_many_requests);
        res.content_type = .TEXT;
        res.body = "rate limit exceeded";
        return;
    }

    return executor.next();
}

fn keyFor(self: *const rateLimiter, req: *httpz.Request) ?u64 {
    if (self.key_mode == .header) {
        if (req.header(self.header_name)) |h| {
            return std.hash.XxHash3.hash(0, h);
        }
    }
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{}", .{req.address}) catch return null;
    return std.hash.XxHash3.hash(0, s);
}
