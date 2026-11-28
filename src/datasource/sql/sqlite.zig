const std = @import("std");
const root = @import("../../zero.zig");

const SQLite = @This();

// A saturated pool never fails the request: callers queue until a connection is
// returned. Each connection still gets a SQLite busy_timeout (set below) for
// lock contention between concurrent writers.

/// A fixed set of open connections. A caller borrows one for the duration of a
/// call; with WAL enabled, readers on other connections run while a writer holds
/// its own. No lock is held across a query — that is the whole point of the pool.
const Pool = struct {
    allocator: std.mem.Allocator,
    dbs: []root.sqlitez.Db,
    /// Stack of currently free connections. Fixed-size, allocated once at init.
    free: []*root.sqlitez.Db,
    free_len: usize,
    mu: std.Io.Mutex = .init,
    /// Callers with no free connection wait here. `signal` wakes one waiter per
    /// returned connection, so releases are handed out in wake order.
    cond: std.Io.Condition = .init,

    fn acquire(self: *Pool) *root.sqlitez.Db {
        const io = root.utils.io;
        self.mu.lockUncancelable(io);
        while (self.free_len == 0) {
            // waitUncancelable releases the mutex while blocked and reacquires
            // it before returning, so the free-list check stays atomic.
            self.cond.waitUncancelable(io, &self.mu);
        }
        self.free_len -= 1;
        const db = self.free[self.free_len];
        self.mu.unlock(io);
        return db;
    }

    fn release(self: *Pool, db: *root.sqlitez.Db) void {
        const io = root.utils.io;
        self.mu.lockUncancelable(io);
        // A double release would hand the same connection to two requests.
        std.debug.assert(self.free_len < self.free.len);
        self.free[self.free_len] = db;
        self.free_len += 1;
        self.cond.signal(io);
        self.mu.unlock(io);
    }

    fn deinit(self: *Pool) void {
        for (self.dbs) |*db| {
            db.deinit();
        }
        self.allocator.free(self.free);
        self.allocator.free(self.dbs);
        self.allocator.destroy(self);
    }
};

allocator: std.mem.Allocator,
log: *root.logger,
metricz: *root.metricz,
pool: *Pool,
/// A transaction pins one connection so every statement in it shares a snapshot.
/// Cleared by commit/rollback. Dropping a request mid-transaction leaves it
/// pinned, matching the existing Postgres/MySQL session behaviour.
tx_conn: ?*root.sqlitez.Db = null,
/// Captured per session right after each exec, so a concurrent request cannot
/// overwrite this session's last-insert-id / affected-row count.
last_id: i64 = 0,
rows: usize = 0,

pub fn init(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    create: bool,
    write: bool,
    threading_mode: root.sqlitez.ThreadingMode,
    l: *root.logger,
    m: *root.metricz,
    pool_size: usize,
) !*SQLite {
    const db_path_z = try allocator.dupeSentinel(u8, db_path, 0);
    errdefer allocator.free(db_path_z);

    const source = try allocator.create(SQLite);
    errdefer allocator.destroy(source);

    const dbs = try allocator.alloc(root.sqlitez.Db, pool_size);
    errdefer allocator.free(dbs);
    var opened: usize = 0;
    errdefer {
        for (dbs[0..opened]) |*db| {
            db.deinit();
        }
    }

    for (dbs) |*db| {
        db.* = try root.sqlitez.Db.init(.{
            .mode = .{ .File = db_path_z },
            .open_flags = .{ .write = write, .create = create },
            .threading_mode = threading_mode,
        });
        opened += 1;
        if (write) {
            // WAL is what lets readers on other connections proceed while this
            // writer is active. A read-only handle cannot change journal mode.
            _ = try db.pragma([128:0]u8, .{}, "journal_mode", "wal");
            // Writers on different connections otherwise fail with SQLITE_BUSY
            // as soon as one of them holds the write lock.
            _ = try db.pragma([128:0]u8, .{}, "busy_timeout", "5000");
        }
    }

    const pool = try allocator.create(Pool);
    errdefer allocator.destroy(pool);
    const free = try allocator.alloc(*root.sqlitez.Db, pool_size);
    errdefer allocator.free(free);

    pool.* = .{ .allocator = allocator, .dbs = dbs, .free = free, .free_len = pool_size };
    for (dbs, 0..) |*db, i| {
        free[i] = db;
    }

    source.* = .{
        .allocator = allocator,
        .log = l,
        .metricz = m,
        .pool = pool,
    };
    return source;
}

/// Close every pooled connection and free the shared handle. Per-request
/// sessions are arena-owned and need no teardown of their own.
pub fn deinit(self: *SQLite) void {
    self.pool.deinit();
    self.allocator.destroy(self);
}

/// Build a per-request session that borrows the shared pool. Keeps transaction
/// and last-id/rows state local so concurrent requests cannot clobber each other.
pub fn createSession(allocator: std.mem.Allocator, shared: *SQLite) !*SQLite {
    const session = try allocator.create(SQLite);
    session.* = .{
        .allocator = shared.allocator,
        .log = shared.log,
        .metricz = shared.metricz,
        .pool = shared.pool,
    };
    return session;
}

fn acquireConn(self: *SQLite) *root.sqlitez.Db {
    if (self.tx_conn) |db| {
        return db;
    }
    return self.pool.acquire();
}

fn releaseConn(self: *SQLite, db: *root.sqlitez.Db) void {
    // The pinned transaction connection belongs to the transaction, not to this
    // individual call.
    if (self.tx_conn != null) {
        return;
    }
    self.pool.release(db);
}

pub fn queryRow(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    return self.queryRowContext(ctx, Type, query, args);
}

pub fn queryRowContext(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    const db = self.acquireConn();
    defer self.releaseConn(db);
    var stmt = try db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.oneAlloc(Type, ctx.allocator, .{}, args);
}

pub fn queryRows(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    return self.queryRowsContext(ctx, Type, query, args);
}

pub fn queryRowsContext(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    const db = self.acquireConn();
    defer self.releaseConn(db);
    var stmt = try db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.all(Type, ctx.allocator, .{}, args);
}

/// Append typed rows into `list` and return the count appended.
/// The vendored sqlitez duplicates text/blob values into `ctx.allocator`, so the
/// rows are request-owned and stay valid until the request arena is reset.
pub fn selectSlice(self: *SQLite, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime query: []const u8, args: anytype) !i64 {
    const rows = try self.queryRowsContext(ctx, Type, query, args);
    for (rows) |r| {
        try list.append(r);
    }
    return @intCast(list.items.len);
}

pub fn execWithContext(self: *SQLite, _: *root.Context, comptime query: []const u8, args: anytype) !i64 {
    const db = self.acquireConn();
    defer self.releaseConn(db);
    var stmt = try db.prepareDynamic(query);
    defer stmt.deinit();
    try stmt.exec(.{}, args);
    // Read both while the connection is still ours; getLastInsertRowID /
    // rowsAffected then become per-session values with no connection access.
    self.last_id = db.getLastInsertRowID();
    self.rows = db.rowsAffected();
    return self.last_id;
}

pub fn rowsAffected(self: *SQLite) usize {
    return self.rows;
}

pub fn lastInsertRowID(self: *SQLite) i64 {
    return self.last_id;
}

/// Begin a transaction. SQLite auto-commits each statement, so an explicit
/// BEGIN/COMMIT pair is required to make a set of writes atomic. The transaction
/// pins one connection so every following statement sees the same snapshot.
pub fn begin(self: *SQLite) !void {
    if (self.tx_conn != null) {
        return error.TransactionAlreadyActive;
    }
    const db = self.pool.acquire();
    errdefer self.pool.release(db);
    try db.execDynamic("BEGIN", .{}, .{});
    self.tx_conn = db;
}

/// Commit the active transaction and return its connection to the pool.
pub fn commit(self: *SQLite) !void {
    const db = self.tx_conn orelse return error.NoActiveTransaction;
    try db.execDynamic("COMMIT", .{}, .{});
    self.tx_conn = null;
    self.pool.release(db);
}

/// Roll back the active transaction (best-effort). A failed rollback cannot be
/// recovered here — the transaction is abandoned either way, so the error is
/// intentionally ignored and the connection still goes back to the pool.
pub fn rollback(self: *SQLite) void {
    const db = self.tx_conn orelse return;
    db.execDynamic("ROLLBACK", .{}, .{}) catch {};
    self.tx_conn = null;
    self.pool.release(db);
}
