const std = @import("std");
const root = @import("zero.zig");
const utils = root.utils;

/// Transactional outbox (opt-in). Wire it with `App.addOutbox(opts)`; the table,
/// poller and retry pattern are shipped here.
///
/// Pattern: inside a DB transaction, after your business writes, call
/// `zero.outbox.enqueue(ctx, table, topic, payload)` to insert a message row. A
/// background cron job (registered by `addOutbox`) periodically polls the table,
/// publishes each pending row via the configured pub/sub backend, and marks it
/// `sent`, retrying up to `max_attempts` times before giving up the row (it stays
/// `pending` with an incremented attempt count so an operator can inspect it).
pub const Options = struct {
    /// Outbox table name. Created lazily (CREATE TABLE IF NOT EXISTS) on first poll.
    table: []const u8 = "outbox_messages",
    /// Cron poll cadence, in minutes (the framework scheduler is minute-resolution).
    poll_interval_minutes: u64 = 1,
    /// Max rows claimed per poll.
    batch_size: u32 = 100,
    /// Give up a row after this many publish attempts (it remains `pending`).
    max_attempts: u32 = 5,
    /// Base retry backoff in ms (informational; the poll cadence drives retries).
    base_backoff_ms: u64 = 1000,
};

/// Placeholder for positional argument `n`. Postgres/DuckGres use `$N`; every
/// other backend uses `?`. Always returns an allocator-owned slice.
fn ph(alloc: std.mem.Allocator, dialect: root.datasourceInterface.Dialect, n: usize) ![]const u8 {
    if (dialect == .postgres or dialect == .duckgres) {
        return std.fmt.allocPrint(alloc, "${d}", .{n});
    }
    return alloc.dupe(u8, "?");
}

/// Dialect-aware `CREATE TABLE IF NOT EXISTS` for the outbox. Covers the four
/// primary SQL backends; other dialects fall back to the Postgres shape (tune
/// for your engine — ClickHouse in particular needs a storage engine clause).
pub fn ddlFor(alloc: std.mem.Allocator, table: []const u8, dialect: root.datasourceInterface.Dialect) ![]const u8 {
    const id_col = switch (dialect) {
        .sqlite => "id INTEGER PRIMARY KEY AUTOINCREMENT",
        .mysql => "id BIGINT AUTO_INCREMENT PRIMARY KEY",
        .postgres, .duckgres => "id BIGSERIAL PRIMARY KEY",
        .duckdb => "id BIGINT PRIMARY KEY",
        else => "id BIGINT PRIMARY KEY",
    };
    const now = switch (dialect) {
        .sqlite => "CURRENT_TIMESTAMP",
        else => "NOW()",
    };
    const text = switch (dialect) {
        .clickhouse => "String",
        else => "TEXT",
    };
    const intt = switch (dialect) {
        .clickhouse => "Int32",
        else => "INTEGER",
    };
    return std.fmt.allocPrint(
        alloc,
        "CREATE TABLE IF NOT EXISTS {s} (" ++
            "  {s}," ++
            "  topic {s} NOT NULL," ++
            "  payload {s} NOT NULL," ++
            "  status {s} NOT NULL DEFAULT 'pending'," ++
            "  attempts {s} NOT NULL DEFAULT 0," ++
            "  created_at TIMESTAMP NOT NULL DEFAULT {s}," ++
            "  next_attempt_at TIMESTAMP NOT NULL DEFAULT {s}" ++
            ")",
        .{ table, id_col, text, text, text, intt, now, now },
    );
}

/// Pure backoff helper: 2^(attempt-1) * base_ms, capped at 60s. `attempt` is the
/// 1-based count of attempts already made.
pub fn nextBackoff(attempt: u32, base_ms: u64) u64 {
    if (attempt == 0) return base_ms;
    var v: u128 = base_ms;
    var i: u32 = 0;
    while (i < attempt - 1) : (i += 1) {
        v *= 2;
        if (v > 60_000) {
            v = 60_000;
            break;
        }
    }
    return @intCast(v);
}

const OutboxRow = struct {
    id: i64,
    topic: []const u8,
    payload: []const u8,
};

/// Insert a message row. Call inside the caller's DB transaction so the business
/// write and the outbox entry commit atomically.
pub fn enqueue(ctx: *root.Context, table: []const u8, topic: []const u8, payload: []const u8) !void {
    const alloc = ctx.allocator;
    const d = ctx.SQL.dialect;
    const p1 = try ph(alloc, d, 1);
    defer alloc.free(p1);
    const p2 = try ph(alloc, d, 2);
    defer alloc.free(p2);
    const p3 = try ph(alloc, d, 3);
    defer alloc.free(p3);
    const stmt = try std.fmt.allocPrint(
        alloc,
        "INSERT INTO {s} (topic, payload, status) VALUES ({s}, {s}, {s})",
        .{ table, p1, p2, p3 },
    );
    defer alloc.free(stmt);
    _ = try ctx.SQL.exec(ctx, stmt, .{ topic, payload, "pending" });
}

/// Poll pending rows, publish each, and mark the outcome. Returns the count of
/// rows successfully published this run. Errors are swallowed per-row so one bad
/// row doesn't stall the loop; use the per-row UPDATEs to track attempts.
pub fn pollAndPublish(ctx: *root.Context, pubsub: *root.PubSub, table: []const u8, opts: Options) !u32 {
    const alloc = ctx.allocator;
    const d = ctx.SQL.dialect;

    const ddl = try ddlFor(alloc, table, d);
    defer alloc.free(ddl);
    ctx.SQL.exec(ctx, ddl, .{}) catch {};

    const a1 = try ph(alloc, d, 1);
    defer alloc.free(a1);
    const a2 = try ph(alloc, d, 2);
    defer alloc.free(a2);
    const sel = try std.fmt.allocPrint(
        alloc,
        "SELECT id, topic, payload FROM {s} WHERE status = 'pending' AND attempts < {s} ORDER BY id ASC LIMIT {s}",
        .{ table, a1, a2 },
    );
    defer alloc.free(sel);
    const rows = try ctx.SQL.queryRows(OutboxRow, sel, .{ opts.max_attempts, opts.batch_size });
    defer alloc.free(rows);

    var sent: u32 = 0;
    for (rows) |row| {
        pubsub.PublishRetrying(row.topic, row.payload, .{ .attempts = opts.max_attempts, .backoff_ms = opts.base_backoff_ms }) catch {
            const id_ph = try ph(alloc, d, 1);
            defer alloc.free(id_ph);
            const upd = try std.fmt.allocPrint(
                alloc,
                "UPDATE {s} SET attempts = attempts + 1, next_attempt_at = NOW() WHERE id = {s}",
                .{ table, id_ph },
            );
            defer alloc.free(upd);
            ctx.SQL.exec(ctx, upd, .{row.id}) catch {};
            continue;
        };
        const id_ph = try ph(alloc, d, 1);
        defer alloc.free(id_ph);
        const upd = try std.fmt.allocPrint(
            alloc,
            "UPDATE {s} SET status = 'sent', next_attempt_at = NOW() WHERE id = {s}",
            .{ table, id_ph },
        );
        defer alloc.free(upd);
        ctx.SQL.exec(ctx, upd, .{row.id}) catch {};
        sent += 1;
    }
    return sent;
}

/// Cron hook registered by `App.addOutbox`. No-op until both SQL and a pub/sub
/// backend are configured.
pub fn outboxPoll(ctx: *root.Context) !void {
    const opts = ctx.container.outbox_options orelse return;
    if (ctx.container.SQL == null and ctx.container.MySQL == null and
        ctx.container.SQLite == null and ctx.container.DuckDB == null and
        ctx.container.ClickHouse == null and ctx.container.DuckGres == null)
    {
        return;
    }
    if (!ctx.getPubSubAvailability()) return;
    pollAndPublish(ctx, ctx.pubsub, opts.table, opts) catch |e| {
        ctx.container.log.err("outbox poll failed");
        _ = e;
    };
}

test "outbox placeholder style" {
    const a = std.testing.allocator;
    const postgres = try ph(a, .postgres, 1);
    defer a.free(postgres);
    try std.testing.expectEqualStrings("$1", postgres);
    const sqlite = try ph(a, .sqlite, 1);
    defer a.free(sqlite);
    try std.testing.expectEqualStrings("?", sqlite);
}

test "outbox ddl contains table name and CREATE" {
    const a = std.testing.allocator;
    const ddl = try ddlFor(a, "outbox_messages", .postgres);
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "outbox_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "BIGSERIAL") != null);
}

test "outbox backoff grows and caps" {
    try std.testing.expectEqual(@as(u64, 1000), nextBackoff(1, 1000));
    try std.testing.expectEqual(@as(u64, 2000), nextBackoff(2, 1000));
    try std.testing.expectEqual(@as(u64, 4000), nextBackoff(3, 1000));
    try std.testing.expectEqual(@as(u64, 60000), nextBackoff(100, 1000));
}
