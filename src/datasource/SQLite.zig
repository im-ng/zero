const std = @import("std");
const root = @import("../zero.zig");

const SQLite = @This();
const Self = @This();
const sqlitez = root.sqlitez;

db: sqlitez.Db,
log: *root.logger,
metricz: *root.metricz,
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    dbPath: []const u8,
    create: bool,
    write: bool,
    threading_mode: sqlitez.ThreadingMode,
    l: *root.logger,
    m: *root.metricz,
) !*SQLite {
    const source = try allocator.create(SQLite);
    errdefer allocator.destroy(source);

    const nullTermPath = try allocator.dupeZ(u8, dbPath);

    const options = sqlitez.InitOptions{
        .mode = .{ .File = nullTermPath },
        .open_flags = .{ .write = write, .create = create },
        .threading_mode = threading_mode,
    };

    source.* = SQLite{
        .db = try sqlitez.Db.init(options),
        .log = l,
        .metricz = m,
        .allocator = allocator,
    };

    return source;
}

pub fn queryRow(self: *SQLite, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    var timer = try std.time.Timer.start();

    const result = try self.db.one(Type, query, .{}, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return result;
}

pub fn queryRowContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) !?Type {
    var timer = try std.time.Timer.start();

    const result = try self.db.oneAlloc(Type, alloc, query, .{}, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return result;
}

pub fn queryRows(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) ![]Type {
    var timer = try std.time.Timer.start();

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    const result = try stmt.all(Type, alloc, .{}, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return result;
}

pub fn queryRowsContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) ![]Type {
    var timer = try std.time.Timer.start();

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    const result = try stmt.all(Type, alloc, .{}, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "select");

    return result;
}

pub fn exec(self: *SQLite, comptime query: []const u8, args: anytype) !void {
    var timer = try std.time.Timer.start();

    const options = sqlitez.QueryOptions{};
    try self.db.exec(query, options, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "exec");
}

pub fn execContext(self: *SQLite, comptime query: []const u8, args: anytype) !void {
    var timer = try std.time.Timer.start();

    const options = sqlitez.QueryOptions{};
    try self.db.exec(query, options, args);

    const duration: f32 = @floatFromInt(timer.lap() / 1000000);
    self.recordMetrics(duration, query, "exec");
}

pub fn rowsAffected(self: *SQLite) usize {
    return self.db.rowsAffected();
}

pub fn lastInsertRowID(self: *SQLite) i64 {
    return self.db.getLastInsertRowID();
}

fn recordMetrics(self: *SQLite, duration: f32, query: []const u8, queryType: []const u8) void {
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
    ) catch unreachable;
}
