const std = @import("std");
const root = @import("../zero.zig");
const utils = root.utils;
const SQL = @This();
const Self = @This();

const pgz = root.pgz;
const Results = root.pgz.Result;
const QueryRow = root.pgz.QueryRow;
const context = root.Context;
const sqlStats = root.metricz.AppSQLStatsLabel;
const Mapper = root.pgz.Mapper;

sql: *pgz.Pool,
log: *root.logger,
metricz: *root.metricz = undefined,
config: *dbConfig = undefined,
options: *pgz.Pool.Opts = undefined,

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
    return source;
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
    ) catch unreachable;
}

pub fn queryRow(self: *Self, comptime query: []const u8, args: anytype) !?QueryRow {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = (try conn.row(query, args)) orelse unreachable;

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return rows;
}

pub fn queryRowContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !?QueryRow {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = conn.row(query, args) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return rows;
}

pub fn queryRows(self: *Self, comptime query: []const u8, args: anytype) !*Results {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = conn.query(query, args) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return rows;
}

pub fn queryRowsContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !*Results {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = conn.row(query, args) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return rows;
}

pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !?i64 {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const id = conn.exec(query, args) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "insert");

    return id;
}

pub fn execWithContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !?i64 {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const id = conn.exec(query, args) catch |err| {
        if (err == error.PG) {
            if (conn.err) |pge| {
                self.log.err(pge.message);
            }
        }
        return err;
    };

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "insert");

    return id;
}

pub fn select(self: *Self, comptime _type: anytype, comptime query: []const u8, args: anytype) !?_type {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const row = try conn.queryOpts(query, args, .{ .column_names = true });
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
    comptime _type: anytype,
    list: *std.array_list.Managed(_type),
    comptime query: []const u8,
    args: anytype,
) !i64 {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = try conn.queryOpts(query, args, .{ .column_names = true });
    defer rows.deinit();

    var res = rows.mapper(_type, .{ .dupe = true });
    while (try res.next()) |T| {
        try list.append(T);
    }

    const duration: f32 = utils.elapsedMs(start);
    self.recordMetrics(duration, query, "select");

    return 0;
}
