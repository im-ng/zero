const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;
const constants = root.constants;
const SQL = @This();
const Self = @This();

const pgz = root.pgz;
const Results = root.pgz.Result;
const QueryRow = root.pgz.QueryRow;
const context = root.Context;
const sqlStats = root.metricz.AppSQLStatsLabel;
const Mapper = root.pgz.Mapper;

/// Hard ceiling on rows a single query may materialize in memory. A result
/// set larger than this is a runaway query (missing LIMIT) and must fail fast
/// rather than grow the allocator without bound.
const max_query_rows: usize = 10_000;

sql: *pgz.Pool,
log: *root.logger,
metricz: *root.metricz = undefined,
config: *dbConfig = undefined,
options: *pgz.Pool.Opts = undefined,
allocator: std.mem.Allocator = undefined,
lastId: i64 = 0,
rows: usize = 0,
// When non-null, all statements run on this single pinned connection so a set
// of writes can be wrapped in one transaction (see begin/commit/rollback).
transaction_conn: ?*pgz.Conn = null,
/// Per-statement timeout (ms) applied to every query/exec. null = no timeout.
statement_timeout_ms: ?u32 = constants.DEFAULT_STATEMENT_TIMEOUT_MS,

// is this neccessary?
pub const dbConfig = struct {
    databaseName: []const u8 = undefined,
    hostname: []const u8 = undefined,
    username: []const u8 = undefined,
    password: []const u8 = undefined,
    dialect: []const u8 = undefined,
    port: []const u8 = undefined,
    sslMode: []const u8 = undefined,
    charSet: []const u8 = undefined,
};

pub fn create(allocator: std.mem.Allocator, c: *dbConfig, l: *root.logger, m: *root.metricz) !*SQL {
    const source = try allocator.create(SQL);
    errdefer allocator.destroy(source);
    source.config = c;
    source.log = l;
    source.metricz = m;
    source.transaction_conn = null;
    return source;
}

/// Closes the underlying connection pool and frees the `SQL` struct's own state.
/// The request-scoped sessions borrow this pool and are freed via their arenas.
pub fn deinit(self: *SQL) void {
    self.sql.deinit();
}

/// Build a per-request session that borrows the shared connection `Pool` but
/// keeps its own transaction/last-id/rows state. This is what `Context.init`
/// hands to each HTTP request so that concurrent requests never share a
/// transaction connection or clobber each other's `lastId`/`rows`
/// (see `transaction_conn`/`lastId`/`rows` on this struct). The returned pointer
/// is request-scoped and is freed when the request arena is reset.
pub fn createSession(allocator: std.mem.Allocator, shared: *SQL) !*SQL {
    const session = try allocator.create(SQL);
    session.* = SQL{
        .sql = shared.sql,
        .log = shared.log,
        .metricz = shared.metricz,
        .config = shared.config,
        .options = shared.options,
        .allocator = shared.allocator,
        .lastId = 0,
        .rows = 0,
        .transaction_conn = null,
        .statement_timeout_ms = shared.statement_timeout_ms,
    };
    return session;
}

pub fn Dialect(self: *Self) []const u8 {
    return self.config.dialect;
}

pub fn recordMetrics(self: *Self, duration: f32, query: []const u8, queryType: []const u8) void {
    _ = query;
    _ = queryType;
    self.*.metricz.sqlResponse(
        .{
            .hostname = "",
            .database = "",
            .query = "",
            .operation = "",
        },
        duration,
    ) catch {};
}

pub fn queryRowContext(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    return self.queryRow(ctx, Type, query, args);
}

pub fn queryRowsContext(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    return self.queryRows(ctx, Type, query, args);
}

pub fn queryRow(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    var maybe = conn.rowOpts(query, args, .{ .timeout = self.statement_timeout_ms }) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    if (maybe) |*row| {
        defer row.deinit() catch {};
        return try row.to(Type, .{ .allocator = ctx.allocator });
    }
    return null;
}

pub fn queryRows(self: *Self, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    const rows = conn.queryOpts(query, args, .{ .column_names = true, .timeout = self.statement_timeout_ms }) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };
    defer rows.deinit();

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    var list = std.array_list.Managed(Type).init(ctx.allocator);
    var res = rows.mapper(Type, .{ .allocator = ctx.allocator });
    while (try res.next()) |t| {
        if (list.items.len >= max_query_rows) return error.ResultSetExceedsLimit;
        try list.append(t);
    }
    return try list.toOwnedSlice();
}

pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !i64 {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    const id = conn.execOpts(query, args, .{ .timeout = self.statement_timeout_ms }) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "insert");

    self.lastId = id orelse 0;
    self.rows = 0;
    return self.lastId;
}

pub fn execWithContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !i64 {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    const id = conn.execOpts(query, args, .{ .timeout = self.statement_timeout_ms }) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "insert");

    self.lastId = id orelse 0;
    self.rows = 0;
    return self.lastId;
}

pub fn lastInsertRowID(self: *Self) i64 {
    return self.lastId;
}

pub fn rowsAffected(self: *Self) usize {
    return self.rows;
}

pub fn select(self: *Self, comptime _type: anytype, comptime query: []const u8, args: anytype) !?_type {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    const row = try conn.queryOpts(query, args, .{ .column_names = true, .timeout = self.statement_timeout_ms });
    defer row.deinit();

    var result: _type = undefined;
    while (try row.next()) |_row| {
        result = try _row.to(_type, .{});
    }

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return result;
}

pub fn selectSlice(
    self: *Self,
    _: *root.Context,
    comptime _type: anytype,
    list: *std.array_list.Managed(_type),
    comptime query: []const u8,
    args: anytype,
) !i64 {
    const start = utils.nowMonotonic();

    const conn = try self.acquireConn();
    defer self.releaseConn(conn);

    const rows = try conn.queryOpts(query, args, .{ .column_names = true, .timeout = self.statement_timeout_ms });
    defer rows.deinit();

    var res = rows.mapper(_type, .{ .dupe = true });
    while (try res.next()) |T| {
        if (list.items.len >= max_query_rows) return error.ResultSetExceedsLimit;
        try list.append(T);
    }

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return 0;
}

/// Acquire a connection for a statement. Inside a transaction (see `begin`) the
/// pinned connection is returned so every statement shares one transaction.
fn acquireConn(self: *Self) !*pgz.Conn {
    if (self.transaction_conn) |c| return c;
    return try self.sql.acquire();
}

/// Release a connection acquired via `acquireConn`, unless it is the pinned
/// transaction connection (owned by the active transaction).
fn releaseConn(self: *Self, conn: *pgz.Conn) void {
    if (self.transaction_conn != null) return;
    self.sql.release(conn);
}

/// Start a transaction. All subsequent `exec`/`query*` calls run on a single
/// pinned connection until `commit`/`rollback`.
pub fn begin(self: *Self) !void {
    if (self.transaction_conn != null) return error.AlreadyInTransaction;
    const conn = try self.sql.acquire();
    _ = conn.exec("BEGIN", .{}) catch |err| {
        self.sql.release(conn);
        return err;
    };
    self.transaction_conn = conn;
}

/// Commit the active transaction and release the pinned connection.
pub fn commit(self: *Self) !void {
    const conn = self.transaction_conn orelse return error.NotInTransaction;
    _ = conn.exec("COMMIT", .{}) catch |err| {
        self.sql.release(conn);
        self.transaction_conn = null;
        return err;
    };
    self.sql.release(conn);
    self.transaction_conn = null;
}

/// Roll back the active transaction (best-effort) and release the connection.
pub fn rollback(self: *Self) void {
    if (self.transaction_conn) |conn| {
        _ = conn.exec("ROLLBACK", .{}) catch {};
        self.sql.release(conn);
        self.transaction_conn = null;
    }
}
