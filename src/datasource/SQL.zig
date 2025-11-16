const std = @import("std");
const root = @import("../zero.zig");
const SQL = @This();
const Self = @This();

const pgz = root.pgz;
const Results = root.pgz.Result;
const QueryRow = root.pgz.QueryRow;
const context = root.Context;
const sqlStats = root.metricz.AppSQLStatsLabel;

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
    var timer = try std.time.Timer.start();

    const rows = try self.sql.row(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return rows;
}

pub fn queryRowContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !?QueryRow {
    var timer = try std.time.Timer.start();

    const results = try self.sql.row(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return results;
}

pub fn queryRows(self: *Self, comptime query: []const u8, args: anytype) !*Results {
    var timer = try std.time.Timer.start();

    const results = try self.sql.query(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return results;
}

pub fn queryRowsContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !*Results {
    var timer = try std.time.Timer.start();

    const results = try self.sql.query(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return results;
}

pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !?i64 {
    var timer = try std.time.Timer.start();

    const id = try self.sql.exec(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "insert");

    return id;
}

pub fn execWithContext(self: *Self, _: *context, comptime query: []const u8, args: anytype) !?i64 {
    var timer = try std.time.Timer.start();

    const id = try self.sql.exec(query, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "insert");

    return id;
}

pub fn select(self: *Self, comptime _type: anytype, comptime query: []const u8, args: anytype) !?_type {
    var timer = try std.time.Timer.start();

    const row = self.sql.row(query, args);
    defer row.deinit() catch {};

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    const result = try row.to(_type, .{});
    return result;
}

pub fn selectSlice(self: *Self, comptime _type: anytype, comptime query: []const u8, args: anytype) !*Results {
    var timer = try std.time.Timer.start();

    const row = self.sql.queryOpts(query, args);
    defer row.deinit() catch {};

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    const results = try row.mapper(_type, .{});
    return results;
}
