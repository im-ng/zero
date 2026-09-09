const std = @import("std");
const root = @import("zero.zig");
const server = @This();
const Self = @This();
const Thread = std.Thread;
const httpz = root.httpz;
const constants = root.constants;
const utils = root.utils;

// Pointer to the app's metric registry, set at create() time. The standalone
// metrics server has no `Context`, so the `/metrics` handler reaches the
// registry through this single-process global.
var appMetricz: ?*root.metricz = null;

port: u16 = 0,
container: *root.container = undefined,
m: httpz.Server(void) = undefined,

pub fn create(allocator: std.mem.Allocator, container: *root.container) !*server {
    const mzs = try allocator.create(server);
    errdefer allocator.destroy(mzs);

    mzs.* = .{
        .container = container,
    };

    mzs.port = try container.config.getAsInt("METRICS_PORT");
    if (mzs.port == 0) {
        mzs.port = constants.METRICZ_PORT;
    }

    appMetricz = container.metricz;

    return mzs;
}

pub fn Run(self: *Self) !Thread {
    self.m = try httpz.Server(void).init(
        utils.io,
        self.container.allocator,
        .{
            .address = httpz.Config.Address.all(self.port),
        },
        {},
    );

    var router = try self.m.router(.{});
    router.get("/metrics", metrics, .{});

    return try self.m.listenInNewThread();
}

fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    if (appMetricz) |mz| {
        try mz.writeRaw(std.heap.page_allocator, res.writer());
    }
}

/// Closes the listener so the metrics thread unblocks and exits. Safe to call
/// from a signal handler (no allocation / teardown). Pair with `deinit()` once
/// the thread has been joined.
pub fn stop(self: *Self) void {
    self.m.stop();
}

pub fn deinit(self: *Self) void {
    self.m.deinit();
}
