const std = @import("std");
const Self = @This();
const migrations = @This();
const zero = @import("zero");

const App = zero.App;
const migrate = zero.migrate;
const create_users_postgres = @import("create_users_postgres.zig");

/// Register every dialect's `users` migration. The runner applies only the one
/// whose `.dialect` matches the active `DB_DIALECT`; the others are scoped out
/// and skipped (not recorded), so this pack ships all four DDL variants safely.
pub fn all(app: *App) !void {
    {
        const k = try Key(app, create_users_postgres._migrate);
        try app.addMigration(k, create_users_postgres._migrate);
        app.container.allocator.free(k);
    }
}

fn Key(app: *App, m: *const migrate) ![]const u8 {
    return try std.fmt.allocPrint(app.container.allocator, "{d}", .{m.migrationNumber});
}
