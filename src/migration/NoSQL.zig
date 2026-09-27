const std = @import("std");
const root = @import("../zero.zig");

const Context = root.Context;
const migrate = root.migrate;
const utils = root.utils;

/// Migration bookkeeping for the NoSQL interface (Cassandra today; the same
/// `ctx.NoSQL.put`/`query` path works for any CQL/N1QL backend). A single
/// `zero_migrations` table records every applied migration by `epoch`. CQL has
/// no transactions, so an applied migration is simply recorded after `m.run`
/// succeeds — partial applies are not rolled back.
/// Create the bookkeeping table if absent. Runs once per `runMigrations()` call.
pub fn checkAndCreateMigrationTable(ctx: *Context) !void {
    const n = ctx.NoSQL orelse return;
    try n.put(ctx, "CREATE TABLE IF NOT EXISTS zero_migrations (" ++
        "epoch bigint, execution text, start_time text, duration bigint, " ++
        "PRIMARY KEY (epoch))");
    ctx.info("nosql migration table created");
}

/// Highest applied `epoch`, or 0 when none / table empty. Parses the JSON the
/// Cassandra client returns; the buffer and parsed tree are both freed here so
/// nothing leaks on the request allocator.
pub fn lastMigration(ctx: *Context) !i64 {
    const n = ctx.NoSQL orelse return 0;
    const raw = n.query(ctx, "SELECT epoch, execution, start_time, duration FROM zero_migrations") catch return 0;
    defer ctx.allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();

    if (parsed.value != .array) return 0;
    var max_epoch: i64 = 0;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("epoch")) |e| {
            if (e == .integer and e.integer > max_epoch) {
                max_epoch = e.integer;
            }
        }
    }
    return max_epoch;
}

/// Record an applied migration. `epoch`/`execution`/`duration` are
/// framework-controlled, so interpolating them into the CQL string is safe.
pub fn insertMigration(ctx: *Context, m: *const migrate, duration: u64) !void {
    const n = ctx.NoSQL orelse return;
    const startTime = try utils.sqlTimestampz(ctx.allocator);
    defer ctx.allocator.free(startTime);

    const stmt = try std.fmt.allocPrint(ctx.allocator, "INSERT INTO zero_migrations (epoch, execution, start_time, duration) VALUES ({d}, 'UP', '{s}', {d})", .{ m.migrationNumber, startTime, duration });
    defer ctx.allocator.free(stmt);

    try n.put(ctx, stmt);
}
