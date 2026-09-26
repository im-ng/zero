const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");

const App = zero.App;
const migrate = zero.migrate;
const utils = zero.utils;
const createUser = @import("createUser.zig");

pub fn all(app: *App) !void {
    try app.addMigration(try Key(app, createUser._migrate), createUser._migrate);
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try utils.toStringFromInt(app.container.allocator, "{d}", m.migrationNumber);
}
