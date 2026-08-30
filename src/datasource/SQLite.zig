const std = @import("std");
const root = @import("../zero.zig");

const SQLite = @This();

allocator: std.mem.Allocator,
log: *root.logger,
metricz: *root.metricz,
db: root.sqlitez.Db,

pub fn init(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    create: bool,
    write: bool,
    threading_mode: root.sqlitez.ThreadingMode,
    l: *root.logger,
    m: *root.metricz,
) !*SQLite {
    const db_path_z = try allocator.dupeZ(u8, db_path);

    const source = try allocator.create(SQLite);
    errdefer allocator.destroy(source);

    source.* = SQLite{
        .allocator = allocator,
        .log = l,
        .metricz = m,
        .db = undefined,
    };

    source.db = try root.sqlitez.Db.init(.{
        .mode = .{ .File = db_path_z },
        .open_flags = .{ .write = write, .create = create },
        .threading_mode = threading_mode,
    });

    return source;
}

pub fn queryRow(self: *SQLite, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.one(Type, .{}, args);
}

pub fn queryRowContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) !?Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.oneAlloc(Type, alloc, .{}, args);
}

pub fn queryRows(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) ![]Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.all(Type, alloc, .{}, args);
}

pub fn queryRowsContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) ![]Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.all(Type, alloc, .{}, args);
}

pub fn exec(self: *SQLite, comptime query: []const u8, args: anytype) !void {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.exec(.{}, args);
}

pub fn execContext(self: *SQLite, comptime query: []const u8, args: anytype) !void {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.exec(.{}, args);
}

pub fn rowsAffected(self: *SQLite) usize {
    return self.db.rowsAffected();
}

pub fn lastInsertRowID(self: *SQLite) i64 {
    return self.db.getLastInsertRowID();
}
