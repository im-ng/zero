const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");

const App = zero.App;
const migrate = zero.migrate;
const utils = zero.utils;
const createUser = @import("createUser.zig");

pub fn all(app: *App) !void {
    {
        const k = try Key(app, createUser._migrate);
        try app.addMigration(k, createUser._migrate);
        app.container.allocator.free(k);
    }
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try std.fmt.allocPrint(app.container.allocator, "{d}", .{m.migrationNumber});
}
