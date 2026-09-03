const std = @import("std");
const root = @import("../zero.zig");

fn envGet(name: []const u8) ?[]const u8 {
    const ptr = std.c.environ;
    var i: usize = 0;
    while (ptr[i] != null) : (i += 1) {
        const slice = std.mem.span(ptr[i].?);
        const eq = std.mem.indexOfScalar(u8, slice, '=') orelse continue;
        if (std.mem.eql(u8, slice[0..eq], name)) {
            return slice[eq + 1 ..];
        }
    }
    return null;
}

fn envOr(allocator: std.mem.Allocator, name: []const u8, default: []const u8) []const u8 {
    _ = allocator;
    return envGet(name) orelse default;
}

// Real-database integration tests. Kept out of the kcov-traced coverage build
// because `sqlitez.Db.init` aborts under kcov's ptrace. Run them via the separate
// `zig build test-integration` step (locally and in CI) where native drivers are
// allowed and no coverage instrumentation is applied.
test "datasource sqlite backend integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const log = try root.logger.create(allocator);
    defer allocator.destroy(log);
    const m = try root.metricz.initialize(allocator, .{ .prefix = "", .exclude = null });
    defer allocator.destroy(m);

    const sqlite = try root.SQLite.init(allocator, ":memory:", true, true, root.sqlitez.ThreadingMode.MultiThread, log, m);
    defer {
        sqlite.db.deinit();
        allocator.destroy(sqlite);
    }

    // Unified handle; the caller never names the concrete backend.
    const ds = root.Datasource.init(sqlite, .sqlite);

    var ctx_storage: root.Context = undefined;
    ctx_storage.allocator = allocator;
    const ctx = &ctx_storage;

    _ = try ds.exec(ctx,
        \\CREATE TABLE IF NOT EXISTS person (id INTEGER PRIMARY KEY AUTOINCREMENT, age INTEGER NOT NULL)
    , .{});

    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 42)});
    const last = ds.lastInsertRowID();
    try std.testing.expectEqual(@as(i64, 1), last);

    const Person = struct { id: i64, age: i64 };

    // queryRow returns ?Type directly.
    const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expect(one != null);
    try std.testing.expectEqual(@as(i64, 42), one.?.age);

    // select alias of queryRow.
    const sel = try ds.select(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(i64, 42), sel.?.age);

    // query alias of queryRow.
    const q = try ds.query(ctx, Person, "SELECT id, age FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(i64, 42), q.?.age);

    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES (?)", .{@as(i64, 7)});

    // queryRows returns an owned []Type.
    const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    // selectSlice appends into a caller-owned list.
    var list = std.array_list.Managed(Person).init(allocator);
    defer list.deinit();
    const n = try ds.selectSlice(ctx, Person, &list, "SELECT id, age FROM person ORDER BY id", .{});
    try std.testing.expectEqual(@as(i64, 2), n);

    _ = try ds.exec(ctx, "DELETE FROM person WHERE id = ?", .{last});
    try std.testing.expectEqual(@as(usize, 1), ds.rowsAffected());
}

test "datasource postgres backend integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Only attempt a connection when DB_HOST is explicitly set, so the test
    // skips cleanly (without triggering the driver's error log) in environments
    // that have no Postgres configured.
    const host = envGet("DB_HOST") orelse {
        std.debug.print("DB_HOST not set, skipping postgres integration test\n", .{});
        return;
    };
    const port = std.fmt.parseInt(u16, envOr(allocator, "DB_PORT", "5432"), 10) catch 5432;
    const user = envOr(allocator, "DB_USER", "postgres");
    const password = envOr(allocator, "DB_PASSWORD", "postgres");
    const database = envOr(allocator, "DB_NAME", "postgres");

    var options: root.pgz.Pool.Opts = .{
        .size = 1,
        .connect = .{ .host = host, .port = port },
        .auth = .{
            .application_name = "zero-test",
            .username = user,
            .password = password,
            .database = database,
            .timeout = 3000,
        },
        .timeout = 3000,
    };

    const pool = root.pgz.Pool.init(root.utils.io, allocator, options) catch |err| {
        std.debug.print("postgres pool init failed ({s}), skipping integration test\n", .{@errorName(err)});
        return;
    };

    const log = try root.logger.create(allocator);
    defer allocator.destroy(log);
    const m = try root.metricz.initialize(allocator, .{ .prefix = "", .exclude = null });
    defer allocator.destroy(m);

    var cfg: root.SQL.dbConfig = .{};
    const sql = try root.SQL.create(allocator, &cfg, log, m);
    sql.sql = pool;
    sql.options = &options;
    sql.metricz = m;
    sql.allocator = allocator;

    const ds = root.Datasource.init(sql, .postgres);

    var ctx_storage: root.Context = undefined;
    ctx_storage.allocator = allocator;
    const ctx = &ctx_storage;

    // Probe connectivity; skip the test when no Postgres server is reachable so
    // local `zig build test-integration` still passes without one running.
    _ = ds.exec(ctx, "DROP TABLE IF EXISTS person", .{}) catch {
        std.debug.print("postgres not reachable, skipping integration test\n", .{});
        return;
    };

    _ = try ds.exec(ctx, "CREATE TABLE person (id SERIAL PRIMARY KEY, age INTEGER NOT NULL)", .{});
    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES ($1)", .{@as(i64, 42)});

    const Person = struct { id: i64, age: i64 };
    const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE age = $1", .{@as(i64, 42)});
    try std.testing.expect(one != null);
    try std.testing.expectEqual(@as(i64, 42), one.?.age);

    const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);

    _ = try ds.exec(ctx, "DROP TABLE IF EXISTS person", .{});
}
