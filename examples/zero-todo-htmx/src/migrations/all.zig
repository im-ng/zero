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
    try app.addMigration(
        try Key(app, createTodoTable._migrate),
        createTodoTable._migrate,
    );

    try app.addMigration(
        try Key(app, addTodoEntries._migrate),
        addTodoEntries._migrate,
    );
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    const key = try utils.toStringFromInt(
        app.container.allocator,
        "{d}",
        m.migrationNumber,
    );
    return key;
}
