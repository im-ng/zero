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
allocator: std.mem.Allocator = undefined,
lastId: i64 = 0,
rows: usize = 0,

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

pub fn queryRowContext(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    return self.queryRow(ctx, Type, query, args);
}

pub fn queryRowsContext(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    return self.queryRows(ctx, Type, query, args);
}

pub fn queryRow(self: *Self, ctx: *context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    const start = utils.nowMonotonic();

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    var maybe = conn.row(query, args) catch |err| {
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

    const conn = try self.sql.acquire();
    defer self.sql.release(conn);

    const rows = conn.queryOpts(query, args, .{ .column_names = true }) catch |err| {
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
    while (try res.next()) |t| try list.append(t);
    return try list.toOwnedSlice();
}

pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !i64 {
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

    self.lastId = id orelse 0;
    self.rows = 0;
    return self.lastId;
}

pub fn execWithContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !i64 {
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
    _: *root.Context,
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
