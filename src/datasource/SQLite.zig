const std = @import("std");
const root = @import("../zero.zig");

const SQLite = @This();
const Self = @This();

// Deferred sqlite stub. The real im-ng/zig-sqlite (0.16-compatible) should
// replace this once its build is ready. Methods compile but return errors so
// the framework builds without the C amalgamation.
pub const SqliteDisabled = error.SqliteDisabled;

allocator: std.mem.Allocator,
log: *root.logger,
metricz: *root.metricz,

pub fn init(
    allocator: std.mem.Allocator,
    dbPath: []const u8,
    create: bool,
    write: bool,
    threading_mode: root.sqlitez.ThreadingMode,
    l: *root.logger,
    m: *root.metricz,
) error{SqliteDisabled}!*SQLite {
    _ = dbPath;
    _ = create;
    _ = write;
    _ = threading_mode;
    const source = allocator.create(SQLite) catch @panic("sqlite alloc failed");
    source.* = SQLite{
        .allocator = allocator,
        .log = l,
        .metricz = m,
    };
    return source;
}

pub fn queryRow(self: *SQLite, comptime Type: type, comptime query: []const u8, args: anytype) error{SqliteDisabled}!?Type {
    _ = self;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn queryRowContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) error{SqliteDisabled}!?Type {
    _ = self;
    _ = alloc;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn queryRows(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) error{SqliteDisabled}![]Type {
    _ = self;
    _ = alloc;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn queryRowsContext(self: *SQLite, comptime Type: type, alloc: std.mem.Allocator, comptime query: []const u8, args: anytype) error{SqliteDisabled}![]Type {
    _ = self;
    _ = alloc;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn exec(self: *SQLite, comptime query: []const u8, args: anytype) error{SqliteDisabled}!void {
    _ = self;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn execContext(self: *SQLite, comptime query: []const u8, args: anytype) error{SqliteDisabled}!void {
    _ = self;
    _ = query;
    _ = args;
    return error.SqliteDisabled;
}

pub fn rowsAffected(self: *SQLite) usize {
    _ = self;
    return 0;
}

pub fn lastInsertRowID(self: *SQLite) i64 {
    _ = self;
    return 0;
}
