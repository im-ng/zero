const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1790080272;

/// Couchbase (document) schema. N1QL needs a primary index before any query can
/// run, so the migration creates one on the configured bucket. Tagged
/// `.backend = .couchbase` so it only runs when Couchbase is the active backend.
pub fn create_schema_couchbase_run(c: *Context) anyerror!void {
    const bucket = c.container.config.get("COUCHBASE_BUCKET");
    const query = try std.fmt.allocPrint(
        c.allocator,
        "CREATE PRIMARY INDEX IF NOT EXISTS ON `{s}`",
        .{bucket},
    );
    defer c.allocator.free(query);
    const r = try c.NoSQL.?.query(c, query);
    c.allocator.free(r);
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .nosql,
    .backend = .couchbase,
    .run = create_schema_couchbase_run,
};
