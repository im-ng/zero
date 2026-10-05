const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1700000004;

pub fn create_users_clickhouse_run(c: *Context) anyerror!void {
    // ClickHouse has no AUTO_INCREMENT, so the handler supplies an explicit id
    // (MAX(id)+1). ORDER BY id lets the MergeTree columnar engine prune scans.
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (
        \\   id UInt64,
        \\   name String,
        \\   email String
        \\ ) ENGINE = MergeTree() ORDER BY id
    ;
    _ = try c.SQL.exec(c, query, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .relational,
    .dialect = .clickhouse,
    .run = create_users_clickhouse_run,
};
