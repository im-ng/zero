const std = @import("std");
const root = @import("../zero.zig");

const wsUpgrader = @This();
const httpz = root.httpz;
const HandlerError = root.httpz.HandlerError;
const zul = root.zul;
const constants = root.constants;

allocator: std.mem.Allocator,
container: ?*root.container = undefined,

pub const Config = struct {
    allocator: std.mem.Allocator,
    container: *root.container,
};

pub fn init(c: Config) !wsUpgrader {
    return .{
        .allocator = c.allocator,
        .container = c.container,
    };
}

pub fn execute(self: *const wsUpgrader, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (self.isWebSocketPath(req) == false) {
        return executor.next();
    }

    res.setStatus(.upgrade_required);

    return executor.next();
}

fn isWebSocketPath(_: *const wsUpgrader, req: *httpz.Request) bool {
    if (std.mem.eql(u8, req.url.path, "/ws")) {
        return true;
    }

    return false;
}
