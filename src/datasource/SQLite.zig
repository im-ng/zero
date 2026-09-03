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

// pub fn queryRow(self: *SQLite, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
//     var stmt = try self.db.prepareDynamic(query);
//     defer stmt.deinit();
//     return try stmt.one(Type, .{}, args);
// }

pub fn queryRow(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    return self.queryRowContext(ctx, Type, query, args);
}

pub fn queryRowContext(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) !?Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.oneAlloc(Type, ctx.allocator, .{}, args);
}

// pub fn queryRows(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) ![]Type {
//     var stmt = try self.db.prepareDynamic(query);
//     defer stmt.deinit();
//     return try stmt.all(Type, alloc, .{}, args);
// }

pub fn queryRows(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    return self.queryRowsContext(ctx, Type, query, args);
}

pub fn queryRowsContext(self: *SQLite, ctx: *root.Context, comptime Type: type, comptime query: []const u8, args: anytype) ![]Type {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.all(Type, ctx.allocator, .{}, args);
}

// pub fn exec(self: *SQLite, comptime query: []const u8, args: anytype) !i64 {
//     var stmt = try self.db.prepareDynamic(query);
//     defer stmt.deinit();
//     try stmt.exec(.{}, args);
//     return self.db.getLastInsertRowID();
// }

/// Append typed rows into `list` and return the count appended.
///
/// Note: sqlitez's `all` borrows text buffers from the live connection, so the
/// returned `[]Type` (and therefore the copies appended here) are only valid
/// for the lifetime of the connection / this request. We intentionally keep the
/// intermediate slice alive (not freed) to avoid dangling text pointers. Prefer
/// `queryRows` when you need fully-owned results.
pub fn selectSlice(self: *SQLite, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime query: []const u8, args: anytype) !i64 {
    const rows = try self.queryRowsContext(ctx, Type, query, args);
    for (rows) |r| try list.append(r);
    return @intCast(list.items.len);
}

pub fn execWithContext(self: *SQLite, _: *root.Context, comptime query: []const u8, args: anytype) !i64 {
    var stmt = try self.db.prepareDynamic(query);
    defer stmt.deinit();
    try stmt.exec(.{}, args);
    return self.db.getLastInsertRowID();
}

pub fn rowsAffected(self: *SQLite) usize {
    return self.db.rowsAffected();
}

pub fn lastInsertRowID(self: *SQLite) i64 {
    return self.db.getLastInsertRowID();
}
