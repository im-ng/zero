const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1790080271;

/// Cassandra (wide-column) schema. CQL uses `text` types and a single primary
/// key; the migration is tagged `.backend = .cassandra` so it only runs when
/// Cassandra is the active `ctx.NoSQL`.
pub fn create_schema_cassandra_run(c: *Context) anyerror!void {
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (id text PRIMARY KEY, data text)
    ;
    const r = try c.NoSQL.?.query(c, query);
    c.allocator.free(r);
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .nosql,
    .backend = .cassandra,
    .run = create_schema_cassandra_run,
};
