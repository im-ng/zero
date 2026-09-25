const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");

const App = zero.App;
const migrate = zero.migrate;
const utils = zero.utils;
const create_schema_and_table = @import("create_schema_and_table.zig");

pub fn all(app: *App) !void {
    try app.addMigration(try Key(app, create_schema_and_table._migrate), create_schema_and_table._migrate);
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try utils.toStringFromInt(app.container.allocator, "{d}", m.migrationNumber);
}