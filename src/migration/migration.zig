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

/// Frees the migration registry maps and the `migration` struct.
pub fn deinit(self: *Self) void {
    self.map.deinit();
    self.keys.deinit();
    self.container.allocator.destroy(self);
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

    // The migration context is stack-allocated and torn down at the end of this
    // function, so free the heap-allocated Postgres session it created. The
    // SQLite/DuckDB/ClickHouse backends reuse a shared, borrowed connection and
    // need no cleanup. (This mirrors what the per-request arena does for HTTP
    // traffic — the arena just resets instead of an explicit free.)
    defer {
        if (self.container.SQL != null) {
            const session = @as(*root.SQL, @ptrCast(@alignCast(ctx.SQL.ptr)));
            ctx.allocator.destroy(session);
        }
    }

    // check and create migration table
    try sqlMigrator.checkAndCreateMigrationTable(ctx);

    const lastMigration = try sqlMigrator.lastMigration(ctx);

    // Serialize migration runs across replicas: a session-level advisory lock so
    // two app instances starting up at once can't apply the same migration
    // concurrently (Postgres only — SQLite has no advisory locks).
    if (self.container.datasource.dialect == .postgres) {
        _ = ctx.SQL.exec(ctx, "SELECT pg_advisory_lock(9112025)", .{}) catch |err| {
            ctx.any(err);
            return error.MigrationLockFailed;
        };
        defer _ = ctx.SQL.exec(ctx, "SELECT pg_advisory_unlock(9112025)", .{}) catch {};
    }

    for (self.keys.items) |key| {
        const keyAsString = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{key},
        );
        // `keyAsString` is only used to look up the migration; free it now so it
        // doesn't leak. `allocPrint` returns a correctly-sized, freeable buffer.
        defer ctx.allocator.free(keyAsString);

        const value = self.map.get(keyAsString);

        if (value) |m| {
            if (m.migrationNumber <= lastMigration) {
                self.migrationSkipped(ctx, m);
                continue;
            }

            const start = util.nowReal();

            ctx.SQL.begin() catch |err| {
                ctx.any(err);
                continue;
            };

            m.run(ctx) catch |err| {
                self.executionError(ctx, m);
                ctx.any(err);
                // Do NOT record a failed migration as applied. Roll back whatever the
                // migration did so a partial apply isn't left behind, and leave it
                // *unrecorded* so it is retried on the next run instead of being
                // masked as UP and permanently skipped.
                ctx.SQL.rollback();
                continue;
            };

            const duration: u64 = @as(u64, @intCast(@divFloor(start.nanoseconds, 1_000_000)));

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

            self.migrationCompleted(ctx, m);
        }
    }
}

pub fn migrationKey(_: *Self, ctx: *Context, m: *const migrate) ![]const u8 {
    const msg = try util.toStringFromInt(ctx.allocator, "{d}", m.migrationNumber);
    return msg;
}

pub fn migrationCompleted(self: *Self, ctx: *Context, m: *const migrate) void {
    _ = self;
    // `allocPrint` returns a correctly-sized, freeable buffer (unlike the
    // util's `toStringFromInt` which hands back an unfreeable subslice).
    const msg = std.fmt.allocPrint(ctx.allocator, "{d}: migration completed  ", .{m.migrationNumber}) catch return;
    ctx.info(msg);
    ctx.allocator.free(msg);
}

pub fn migrationSkipped(self: *Self, ctx: *Context, m: *const migrate) void {
    _ = self;
    const msg = std.fmt.allocPrint(ctx.allocator, "{d}: migration is skipped  ", .{m.migrationNumber}) catch return;
    ctx.debug(msg);
    ctx.allocator.free(msg);
}

pub fn executionError(self: *Self, ctx: *Context, m: *const migrate) void {
    _ = self;
    const msg = std.fmt.allocPrint(ctx.allocator, "{d}: migration has execution error  ", .{m.migrationNumber}) catch return;
    ctx.err(msg);
    ctx.allocator.free(msg);
}
