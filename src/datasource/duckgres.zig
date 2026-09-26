const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;
const constants = root.constants;
const pgz = root.pgz;

/// Wired (network) DuckDB client.
///
/// DuckDB core ships no first-party wire-protocol server, so this client speaks the
/// PostgreSQL wire protocol to a DuckDB PG-wire front-end (e.g. duckgres / PostDuck)
/// using zero's pure-Zig `pgz` Postgres client. That keeps the duckdb C library out
/// of the link and lets any DuckDB instance be reached over the network. SQL is sent
/// verbatim in the DuckDB dialect; `pgz` is dialect-agnostic at the protocol layer,
/// so no Postgres-specific translation is applied. It is selected at startup via
/// `DB_DIALECT=duckgres` and exposed on the request context as `ctx.SQL`.
pub const DuckGres = struct {
    sql: *pgz.Pool,
    log: *root.logger,
    metricz: *root.metricz = undefined,
    allocator: std.mem.Allocator = undefined,
    last_id: i64 = 0,
    rows: usize = 0,
    transaction_conn: ?*pgz.Conn = null,
    statement_timeout_ms: ?u32 = constants.DEFAULT_STATEMENT_TIMEOUT_MS,

    const Self = @This();

    /// Hard ceiling on rows a single query may materialize in memory. A result set
    /// larger than this is a runaway query (missing LIMIT) and must fail fast
    /// rather than grow the allocator without bound.
    const max_query_rows: usize = 10_000;

    /// Build a wired DuckDB client: a connection pool that talks the Postgres wire
    /// protocol to a DuckDB PG-wire front-end. `opts` is the same `pgz.Pool.Opts`
    /// the Postgres backend builds from the shared `DB_*` configuration, so the
    /// two share one connection-config surface. The pool borrows `allocator` for
    /// its lifetime; release it with `deinit`.
    pub fn create(allocator: std.mem.Allocator, opts: pgz.Pool.Opts, l: *root.logger, m: *root.metricz) !*DuckGres {
        const source = try allocator.create(DuckGres);
        errdefer allocator.destroy(source);

        const pool = pgz.Pool.init(utils.io, allocator, opts) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "duckgres: could not init pool: {s}", .{@errorName(err)}) catch "duckgres: could not init pool";
            l.err(msg);
            return err;
        };

        source.* = DuckGres{
            .sql = pool,
            .log = l,
            .metricz = m,
            .allocator = allocator,
            .transaction_conn = null,
        };
        return source;
    }

    /// Close the pool and free the client struct.
    pub fn deinit(self: *DuckGres) void {
        self.sql.deinit();
    }

    pub fn Dialect(_: *Self) []const u8 {
        return "duckgres";
    }

    pub fn lastInsertRowID(self: *Self) i64 {
        return self.last_id;
    }

    pub fn rowsAffected(self: *Self) usize {
        return self.rows;
    }

    /// Single typed row. `null` when the query matches no rows. Decodes into `Type`
    /// using the request allocator so the caller owns the result.
    pub fn queryRow(self: *Self, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
        return self.queryRowContext(ctx, Type, query, args);
    }

    /// All rows decoded into `Type`, owned by the request allocator and capped at
    /// `max_query_rows` to fail fast on runaway result sets.
    pub fn queryRows(self: *Self, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
        return self.queryRowsContext(ctx, Type, query, args);
    }

    /// Context-aware `queryRow`; the request allocator owns the decoded row.
    pub fn queryRowContext(self: *Self, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
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
            // A row deinit error after a successful parse is harmless and must not
            // shadow the already-decoded value.
            defer row.deinit() catch {};
            return try row.to(Type, .{ .allocator = ctx.allocator });
        }
        return null;
    }

    /// Context-aware `queryRows`; the request allocator owns the returned slice.
    pub fn queryRowsContext(self: *Self, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
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

    /// Append typed rows into `list`; returns the number of rows appended.
    pub fn selectSlice(self: *Self, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime query: []const u8, args: anytype) !i64 {
        const rows = try self.queryRowsContext(ctx, Type, query, args);
        for (rows) |r| {
            try list.append(r);
        }
        return @intCast(list.items.len);
    }

    /// Execute a write; returns the command's affected/returned count, which is
    /// also stored as `rowsAffected` so the delete handler can report success.
    pub fn execWithContext(self: *Self, ctx: *root.Context, comptime query: []const u8, args: anytype) !i64 {
        _ = ctx;
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
        self.recordMetrics(duration, query, "exec");

        // `pgz` returns the command tag (affected row count) for writes. Store it as
        // the affected-row count so `rowsAffected` reflects reality (the Postgres
        // backend leaves `rows` at 0, which would make `DELETE` report "not found");
        // the duckgres path is correct.
        self.rows = if (id) |v| @as(usize, @intCast(v)) else 0;
        self.last_id = id orelse 0;
        return self.last_id;
    }

    fn acquireConn(self: *Self) !*pgz.Conn {
        if (self.transaction_conn) |c| return c;
        return try self.sql.acquire();
    }

    fn releaseConn(self: *Self, conn: *pgz.Conn) void {
        if (self.transaction_conn != null) return;
        self.sql.release(conn);
    }

    /// Start a transaction. Subsequent `exec`/`query*` run on one pinned
    /// connection until `commit`/`rollback`.
    pub fn begin(self: *Self) !void {
        if (self.transaction_conn != null) return error.AlreadyInTransaction;
        const conn = try self.sql.acquire();
        _ = conn.exec("BEGIN", .{}) catch |err| {
            self.sql.release(conn);
            return err;
        };
        self.transaction_conn = conn;
    }

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

    pub fn rollback(self: *Self) void {
        if (self.transaction_conn) |conn| {
            // A failed rollback cannot be recovered here; the connection is
            // released regardless, so the error is intentionally ignored.
            _ = conn.exec("ROLLBACK", .{}) catch {};
            self.sql.release(conn);
            self.transaction_conn = null;
        }
    }

    fn recordMetrics(self: *Self, duration: f32, query: []const u8, queryType: []const u8) void {
        _ = query;
        _ = queryType;
        self.metricz.sqlResponse(
            .{
                .hostname = "",
                .database = "",
                .query = "",
                .operation = "",
            },
            duration,
        ) catch {};
    }
};
