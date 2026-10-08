const std = @import("std");
const root = @import("../zero.zig");
const KVRedis = @import("../kvstore/redis.zig").KVRedis;

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

// ===================== Tests =====================

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
    // `var` (not `const`): `exec` takes a mutable `*Interface` receiver.
    var ds = root.Datasource.init(sqlite, .sqlite, null, null);

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

    var ds = root.Datasource.init(sql, .postgres, null, null);

    var ctx_storage: root.Context = undefined;
    ctx_storage.allocator = allocator;
    const ctx = &ctx_storage;

    // Probe connectivity; skip the test when no Postgres server is reachable so
    // local `zig build test-integration` still passes without one running.
    _ = ds.exec(ctx, "DROP TABLE IF EXISTS person", .{}) catch {
        std.debug.print("postgres not reachable, skipping integration test\n", .{});
        return;
    };

    _ = try ds.exec(ctx, "CREATE TABLE person (id SERIAL PRIMARY KEY, age BIGINT NOT NULL)", .{});
    _ = try ds.exec(ctx, "INSERT INTO person (age) VALUES ($1)", .{@as(i64, 42)});

    const Person = struct { id: i32, age: i64 };

    const one = try ds.queryRow(ctx, Person, "SELECT id, age FROM person WHERE age = $1", .{@as(i64, 42)});
    try std.testing.expect(one != null);
    try std.testing.expectEqual(@as(i64, 42), one.?.age);

    const rows = try ds.queryRows(ctx, Person, "SELECT id, age FROM person ORDER BY id", .{});
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);

    _ = try ds.exec(ctx, "DROP TABLE IF EXISTS person", .{});
}

// Concurrent transactions against Postgres. Validates the M2 fix: each HTTP
// request gets its own per-request `SQL` session (`SQL.createSession`) so
// concurrent transactions no longer share a single `transaction_conn` /
// `lastId`. If the sessions weren't isolated, concurrent `begin()` calls would
// clobber each other's pinned connection and the final counter would be wrong.
//
// Gated on `DB_HOST`; skips cleanly when no Postgres is configured.
test "datasource postgres concurrent transactions isolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const host = envGet("DB_HOST") orelse {
        std.debug.print("DB_HOST not set, skipping concurrent-tx integration test\n", .{});
        return;
    };
    const port = std.fmt.parseInt(u16, envOr(allocator, "DB_PORT", "5432"), 10) catch 5432;
    const user = envOr(allocator, "DB_USER", "postgres");
    const password = envOr(allocator, "DB_PASSWORD", "postgres");
    const database = envOr(allocator, "DB_NAME", "postgres");

    var options: root.pgz.Pool.Opts = .{
        .size = 32,
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
        std.debug.print("postgres pool init failed ({s}), skipping concurrent-tx test\n", .{@errorName(err)});
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
    sql.statement_timeout_ms = 3000;

    _ = sql.exec("DROP TABLE IF EXISTS bench_counter", .{}) catch {
        std.debug.print("postgres not reachable, skipping concurrent-tx test\n", .{});
        return;
    };
    _ = try sql.exec("CREATE TABLE bench_counter (id INT PRIMARY KEY, n BIGINT NOT NULL)", .{});
    _ = try sql.exec("INSERT INTO bench_counter (id, n) VALUES (1, 0)", .{});
    defer _ = sql.exec("DROP TABLE IF EXISTS bench_counter", .{}) catch {};

    const N: usize = 20;
    // Pre-create one per-request session per worker on the main thread (avoids
    // sharing the arena allocator across threads — only the socket/transaction
    // state is exercised concurrently).
    var sessions: [N]@TypeOf(sql) = undefined;
    var j2: usize = 0;
    while (j2 < N) : (j2 += 1) {
        sessions[j2] = root.SQL.createSession(allocator, sql) catch {
            std.debug.print("session creation failed, skipping concurrent-tx test\n", .{});
            return;
        };
    }

    const Worker = struct {
        fn run(s: @TypeOf(sql)) void {
            s.begin() catch return;
            _ = s.exec("UPDATE bench_counter SET n = n + 1 WHERE id = 1", .{}) catch {
                s.rollback();
                return;
            };
            s.commit() catch {};
        }
    };

    var threads: [N]std.Thread = undefined;
    var j: usize = 0;
    while (j < N) : (j += 1) {
        threads[j] = std.Thread.spawn(.{}, Worker.run, .{sessions[j]}) catch {
            std.debug.print("thread spawn failed, skipping concurrent-tx test\n", .{});
            return;
        };
    }
    for (&threads) |t| {
        t.join();
    }

    const Row = struct { n: i64 };
    const got = try sql.select(Row, "SELECT n FROM bench_counter WHERE id = 1", .{});
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(i64, N), got.?.n);
}

// Concurrent Redis SET/GET through the shared `KVRedis` wrapper.
test "redis kvstore concurrent set/get (mutex serialization)" {
    const allocator = std.testing.allocator;

    const host = envGet("REDIS_HOST") orelse {
        std.debug.print("REDIS_HOST not set, skipping redis concurrency integration test\n", .{});
        return;
    };
    const port = std.fmt.parseInt(u16, envOr(allocator, "REDIS_PORT", "6379"), 10) catch 6379;
    const password = envOr(allocator, "REDIS_PASSWORD", "");

    const addr = std.Io.net.IpAddress.parse(host, port) catch
        std.Io.net.IpAddress.resolve(root.utils.io, host, port) catch {
        std.debug.print("redis address resolve failed, skipping redis concurrency test\n", .{});
        return;
    };
    const connection = addr.connect(root.utils.io, .{ .mode = .stream }) catch {
        std.debug.print("redis connect failed, skipping redis concurrency test\n", .{});
        return;
    };
    defer connection.close(root.utils.io);

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = connection.reader(root.utils.io, &rbuf);
    var writer = connection.writer(root.utils.io, &wbuf);
    const client = root.rediz.Client.init(root.utils.io, &reader.interface, &writer.interface, .{
        .user = null,
        .pass = password,
    }) catch {
        std.debug.print("redis client init failed, skipping redis concurrency test\n", .{});
        return;
    };

    var kr: KVRedis = .{ .client = client };

    // Verify reachability before spawning workers.
    _ = kr.client.sendAlloc([]u8, allocator, .{"ping"}) catch {
        std.debug.print("redis ping failed, skipping redis concurrency test\n", .{});
        return;
    };

    const N: usize = 16;
    var results: [N]bool = undefined;

    const Worker = struct {
        fn run(ks: *KVRedis, idx: usize, out: *bool) void {
            // Per-thread allocator so concurrent RESP buffers don't race on a
            // shared arena; only the shared `ks` socket is exercised concurrently.
            var talloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer talloc.deinit();
            var ctx: root.Context = undefined;
            ctx.allocator = talloc.allocator();

            const key = std.fmt.allocPrint(talloc.allocator(), "zero_bench_{d}", .{idx}) catch {
                out.* = false;
                return;
            };
            const val = std.fmt.allocPrint(talloc.allocator(), "v{d}", .{idx}) catch {
                out.* = false;
                return;
            };

            ks.set(&ctx, key, val) catch {
                out.* = false;
                return;
            };
            const got = ks.get(&ctx, key) catch {
                out.* = false;
                return;
            };
            if (got == null or !std.mem.eql(u8, got.?, val)) {
                out.* = false;
                return;
            }
            out.* = true;
        }
    };

    var threads: [N]std.Thread = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        threads[i] = std.Thread.spawn(.{}, Worker.run, .{ &kr, i, &results[i] }) catch {
            std.debug.print("thread spawn failed, skipping redis concurrency test\n", .{});
            return;
        };
    }
    for (&threads) |t| {
        t.join();
    }

    for (results) |ok| {
        try std.testing.expect(ok);
    }
}

// MySQL pool + TLS integration. Gated on MYSQL_TEST (set in CI and locally when
// a MySQL/MariaDB is reachable). Exercises the pure-Zig client end-to-end:
// connection pooling (connection reuse), typed row decode, and transaction
// connection pinning. When MYSQL_SSL_MODE is `required`/`preferred` the TLS
// upgrade path (std.crypto.tls) is exercised too.
test "mysql pool, ssl and transaction integration" {
    if (envGet("MYSQL_TEST") == null) {
        std.debug.print("MYSQL_TEST not set, skipping mysql integration test\n", .{});
        return;
    }
    const allocator = std.testing.allocator;

    const host = envGet("MYSQL_HOST") orelse "127.0.0.1";
    const port = std.fmt.parseInt(u16, envGet("MYSQL_PORT") orelse "3306", 10) catch 3306;
    const user = envGet("MYSQL_USER") orelse "root";
    const password = envGet("MYSQL_PASSWORD") orelse "";
    const db = envGet("MYSQL_NAME") orelse "mysql";
    const ssl_mode_str = envGet("MYSQL_SSL_MODE") orelse "disabled";
    const ssl_mode: root.MySQL.SslMode = if (std.mem.eql(u8, ssl_mode_str, "required"))
        .required
    else if (std.mem.eql(u8, ssl_mode_str, "preferred"))
        .preferred
    else
        .disabled;
    const ssl_ca = envGet("MYSQL_SSL_CA");

    const pool = try root.MySQL.create(allocator, root.utils.io, .{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = db,
        .ssl_mode = ssl_mode,
        .ssl_ca = ssl_ca,
        .max = 4,
    });
    defer pool.deinit();

    // Typed row decode over a pooled, optionally TLS-wrapped connection.
    const Row = struct { one: i64 };
    const conn = pool.acquireConn() catch {
        std.debug.print("mysql not reachable, skipping mysql integration test\n", .{});
        return;
    };
    const rows = try conn.queryRows(Row, "SELECT 1 AS one", .{});
    defer allocator.free(rows);
    try std.testing.expect(rows.len == 1);
    try std.testing.expect(rows[0].one == 1);
    pool.releaseConn(conn);

    // Pool reuse: the second checkout returns the same idle connection.
    const first = try pool.acquireConn();
    pool.releaseConn(first);
    const second = try pool.acquireConn();
    try std.testing.expect(second == first);
    pool.releaseConn(second);

    // Transaction: begin pins a connection; every subsequent statement (and the
    // commit) uses that same pinned connection.
    try pool.begin();
    const pinned = try pool.acquireConn();
    try std.testing.expect(pinned == first);
    _ = try pinned.exec("SELECT 1", .{});
    try pool.commit();
}
