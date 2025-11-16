const std = @import("std");
const root = @import("zero.zig");
const server = @This();
const Self = @This();
const Thread = std.Thread;
const httpz = root.httpz;
const constants = root.constants;

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

    return mzs;
}

pub fn Run(self: *Self) !Thread {
    self.m = try httpz.Server(void).init(self.container.allocator, .{
        .port = self.port,
    }, {});

    var router = try self.m.router(.{});
    router.get("/metrics", metrics, .{});

    return try self.m.listenInNewThread();
}

fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    return httpz.writeMetrics(res.writer());
}

pub fn Shutdown(self: *Self) !void {
    self.m.deinit();
    self.m.stop();
}
