const std = @import("std");
const migration = @This();
const Self = @This();
const root = @import("../zero.zig");

const httpz = root.httpz;
const Context = root.Context;
const SQL = root.SQL;
const util = root.utils;
const migrate = root.migrate;
const zdt = root.zdt;

const sqlMigrator = @import("./SQL.zig");

request: *httpz.Request = undefined,
response: *httpz.Response = undefined,
map: std.StringHashMap(*const migrate) = undefined,
keys: std.array_list.Managed(i64) = undefined,
container: *root.container = undefined,

pub fn create(c: *root.container) !*migration {
    const m = try c.allocator.create(migration);
    errdefer c.allocator.destroy(m);

    m.* = .{
        .container = c,
    };

    m.map = std.StringHashMap(*const migrate).init(m.container.allocator);
    m.keys = std.array_list.Managed(i64).init(m.container.allocator);

    return m;
}

pub fn run(self: *Self) anyerror!void {
    std.mem.sort(i64, self.keys.items, {}, std.sort.asc(i64));

    var context = try Context.init(
        self.container.allocator,
        self.container,
        self.request,
        self.response,
    );
    defer context.deinit();
    const ctx = &context;

    // check and create migration table
    try sqlMigrator.checkAndCreateMigrationTable(ctx);

    const lastMigration = try sqlMigrator.lastMigration(ctx);

    for (self.keys.items) |key| {
        const keyAsString = try util.toStringFromInt(ctx.allocator, "{d}", key);

        const value = self.map.get(keyAsString);

        if (value) |m| {
            if (m.migrationNumber <= lastMigration) {
                ctx.debug(try self.migrationSkipped(ctx, m));
                continue;
            }

            var timer = try std.time.Timer.start();

            m.run(ctx) catch |err| switch (err) {
                else => {
                    ctx.err(try self.executionError(ctx, m));
                    ctx.any(err);
                },
            };

            const duration: u64 = timer.lap() / 1000000;

            _ = try sqlMigrator.insertMigration(ctx, m, duration);

            ctx.info(try self.migrationCompleted(ctx, m));
        }
    }
}

pub fn migrationKey(_: *Self, ctx: *Context, m: *const migrate) ![]const u8 {
    const msg = try util.toStringFromInt(ctx.allocator, "{d}", m.migrationNumber);
    return msg;
}

pub fn migrationCompleted(_: *Self, ctx: *Context, m: *const migrate) ![]const u8 {
    const msg = try util.toStringFromInt(ctx.allocator, "{d}: migration completed  ", m.migrationNumber);
    return msg;
}

pub fn migrationSkipped(_: *Self, ctx: *Context, m: *const migrate) ![]const u8 {
    const msg = try util.toStringFromInt(ctx.allocator, "{d}: migration is skipped  ", m.migrationNumber);
    return msg;
}

pub fn executionError(_: *Self, ctx: *Context, m: *const migrate) ![]const u8 {
    const msg = try util.toStringFromInt(ctx.allocator, "{d}: migration has execution error  ", m.migrationNumber);
    return msg;
}
