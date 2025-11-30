const std = @import("std");
const zero = @import("zero");

const models = @import("models.zig");
const migrations = @import("migrations/all.zig");
const handler = @import("handler.zig");

const App = zero.App;
const Context = zero.Context;
const migrate = zero.migrate;
const container = zero.container;
const utils = zero.utils;
const dateTime = zero.zdt.Datetime;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator);

    try migrations.all(app);

    try app.runMigrations();

    try app.get("/todos", handler.getAll);

    try app.get("/todos/:id", handler.getTodo);

    try app.post("/todos", handler.persistTodo);

    try app.put("/todos/:id", handler.updateTodo);

    try app.delete("/todos/:id", handler.deleteTodo);

    try app.post("/done/:id", handler.markDone);

    try app.post("/undone/:id", handler.markUndone);

    try app.run();
}
