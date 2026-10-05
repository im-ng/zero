const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");

const App = zero.App;
const migrate = zero.migrate;
const create_schema_cassandra = @import("create_schema_cassandra.zig");
const create_schema_couchbase = @import("create_schema_couchbase.zig");

/// Register each backend's `users` migration. The runner applies only the one
/// whose `.backend` matches the active NoSQL backend (Cassandra/Couchbase); the
/// other is scoped out and skipped, so this pack ships both CQL and N1QL DDL.
pub fn all(app: *App) !void {
    {
        const k = try Key(app, create_schema_cassandra._migrate);
        try app.addMigration(k, create_schema_cassandra._migrate);
        app.container.allocator.free(k);
    }
    {
        const k = try Key(app, create_schema_couchbase._migrate);
        try app.addMigration(k, create_schema_couchbase._migrate);
        app.container.allocator.free(k);
    }
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try std.fmt.allocPrint(app.container.allocator, "{d}", .{m.migrationNumber});
}
