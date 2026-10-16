const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");
const models = @import("../models.zig");

const App = zero.App;
const migrate = zero.migrate;
const utils = zero.utils;

const createTodoTable = @import("createTodoTable.zig");
const addTodoEntries = @import("addTodoEntries.zig");

pub fn all(app: *App) !void {
    {
        const k = try Key(app, createTodoTable._migrate);
        try app.addMigration(k, createTodoTable._migrate);
        app.container.allocator.free(k);
    }

    {
        const k = try Key(app, addTodoEntries._migrate);
        try app.addMigration(k, addTodoEntries._migrate);
        app.container.allocator.free(k);
    }
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try std.fmt.allocPrint(app.container.allocator, "{d}", .{m.migrationNumber});
}
