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
const utils = root.utils;

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
    const ctx = &context;

    // check and create migration table
    try sqlMigrator.checkAndCreateMigrationTable(ctx);

    const lastMigration = try sqlMigrator.lastMigration(ctx);

    // Serialize migration runs across replicas: a session-level advisory lock so
    // two app instances starting up at once can't apply the same migration
    // concurrently (Postgres only — SQLite has no advisory locks).
    if (self.container.datasource.dialect == .postgres) {
        ctx.SQL.exec(ctx, "SELECT pg_advisory_lock(9112025)", .{}) catch |err| {
            ctx.any(err);
            return error.MigrationLockFailed;
        };
        defer ctx.SQL.exec(ctx, "SELECT pg_advisory_unlock(9112025)", .{}) catch {};
    }

    for (self.keys.items) |key| {
        const keyAsString = try util.toStringFromInt(
            ctx.allocator,
            "{d}",
            key,
        );

        const value = self.map.get(keyAsString);

        if (value) |m| {
            if (m.migrationNumber <= lastMigration) {
                ctx.debug(try self.migrationSkipped(ctx, m));
                continue;
            }

            const start = util.nowReal();

            ctx.SQL.begin() catch |err| {
                ctx.any(err);
                continue;
            };

            m.run(ctx) catch |err| {
                ctx.err(try self.executionError(ctx, m));
                ctx.any(err);
                // Do NOT record a failed migration as applied. Roll back whatever the
                // migration did so a partial apply isn't left behind, and leave it
                // *unrecorded* so it is retried on the next run instead of being
                // masked as UP and permanently skipped.
                ctx.SQL.rollback();
                continue;
            };

            const duration: u64 = @as(u64, @intCast(@divTrunc(start.nanoseconds, 1_000_000)));

            _ = sqlMigrator.insertMigration(ctx, m, duration) catch |err| {
                ctx.any(err);
                ctx.SQL.rollback();
                continue;
            };

            ctx.SQL.commit() catch |err| {
                ctx.any(err);
                ctx.SQL.rollback();
                continue;
            };

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
