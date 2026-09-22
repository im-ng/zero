const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;

/// ClickHouse columnar OLAP SQL backend (HTTP API via `zul`). ClickHouse speaks a
/// full SQL dialect over its HTTP interface (`:8123`), so it reuses the relational
/// `Datasource`/`ctx.SQL` surface like SQLite/Postgres/DuckDB. No native driver or
/// C library is required — the persistent `zul.http.Client` carries every query.
pub const ClickHouse = struct {
    allocator: std.mem.Allocator,
    client: zul.http.Client,
    url: []const u8,
    database: []const u8,
    user: ?[]const u8,
    password: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        database: []const u8 = "",
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
    }) !*ClickHouse {
        const self = try allocator.create(ClickHouse);
        self.* = .{
            .allocator = allocator,
            .client = zul.http.Client.init(utils.io, allocator),
            .url = try allocator.dupe(u8, opts.url),
            .database = try allocator.dupe(u8, opts.database),
            .user = if (opts.user) |u| try allocator.dupe(u8, u) else null,
            .password = if (opts.password) |p| try allocator.dupe(u8, p) else null,
        };
        return self;
    }

    /// Run `sql` over HTTP and return the raw response body, owned by `alloc`.
    /// Caller frees.
    pub fn runRaw(self: *ClickHouse, alloc: std.mem.Allocator, sql: []const u8) ![]u8 {
        const req_url = try std.fmt.allocPrint(alloc, "{s}", .{self.url});
        var req = try self.client.allocRequest(alloc, req_url);
        defer {
            alloc.free(req_url);
            req.deinit();
        }
        req.method = .POST;
        if (self.database.len > 0) try req.query("database", self.database);
        if (self.user) |u| try req.header("X-ClickHouse-User", u);
        if (self.password) |p| try req.header("X-ClickHouse-Key", p);
        req.body(sql);

        var res: zul.http.Response = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) {
            const sb = try res.allocBody(alloc, .{});
            defer sb.deinit();
            std.log.warn("clickhouse query failed: status={d} body={s}", .{ res.status, sb.buf[0..sb.pos] });
            return error.ClickHouseQueryFailed;
        }
        const sb = try res.allocBody(alloc, .{});
        defer sb.deinit();
        return try alloc.dupe(u8, sb.buf[0..sb.pos]);
    }

    /// Build the final SQL from a `comptime` statement plus a tuple of positional
    /// `?` bind arguments, which ClickHouse HTTP does not support natively. `?`
    /// placeholders are replaced left-to-right with SQL-literal-escaped values.
    fn interpolate(self: *ClickHouse, comptime stmt: []const u8, args: anytype) ![]u8 {
        const ArgType = @TypeOf(args);
        if (comptime @typeInfo(ArgType) != .@"struct") return self.allocator.dupe(u8, stmt);
        const fields = @typeInfo(ArgType).@"struct".fields;
        if (fields.len == 0) return self.allocator.dupe(u8, stmt);

        var buf: std.array_list.Managed(u8) = .init(self.allocator);
        var it = std.mem.splitScalar(u8, stmt, '?');
        inline for (fields) |field| {
            if (it.next()) |part| try buf.appendSlice(part);
            try appendLiteral(&buf, @field(args, field.name));
        }
        // Trailing text after the final `?` (if any).
        if (it.next()) |part| try buf.appendSlice(part);
        return try buf.toOwnedSlice();
    }

    fn appendLiteral(buf: *std.array_list.Managed(u8), v: anytype) !void {
        const T = @TypeOf(v);
        const info = @typeInfo(T);
        if (info == .optional) {
            if (v == null) {
                try buf.appendSlice("NULL");
                return;
            }
            return appendLiteral(buf, v.?);
        }
        switch (info) {
            .int, .comptime_int => {
                const s = try std.fmt.allocPrint(buf.allocator, "{d}", .{v});
                defer buf.allocator.free(s);
                try buf.appendSlice(s);
            },
            .float, .comptime_float => {
                const s = try std.fmt.allocPrint(buf.allocator, "{d}", .{v});
                defer buf.allocator.free(s);
                try buf.appendSlice(s);
            },
            .bool => try buf.appendSlice(if (v) "true" else "false"),
            .pointer => |p| {
                const slice: []const u8 = if (p.child == u8)
                    v
                else if (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                    v[0..v.len]
                else
                    @compileError("ClickHouse: unsupported arg type " ++ @typeName(T));
                try buf.append('\'');
                for (slice) |ch| {
                    if (ch == '\'') try buf.append('\'');
                    try buf.append(ch);
                }
                try buf.append('\'');
            },
            else => @compileError("ClickHouse: unsupported arg type " ++ @typeName(T)),
        }
    }

    /// Parse the `FORMAT JSON` response (`{"meta":[...],"data":[...],"rows":N}`)
    /// into a slice of `Type`, owned by `alloc`. The rows reference memory
    /// allocated by the JSON parser, which is freed with the request arena.
    fn parseRows(comptime Type: type, alloc: std.mem.Allocator, body: []const u8) ![]Type {
        const Wrapper = struct { data: []Type };
        const parsed = try std.json.parseFromSlice(
            Wrapper,
            alloc,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        // Do not call parsed.deinit(): it would free the rows we return. The
        // underlying arena is released with the request allocator.
        return parsed.value.data;
    }

    pub fn queryRow(self: *ClickHouse, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        const sql = try self.interpolate(stmt, args);
        defer self.allocator.free(sql);
        const full = try std.fmt.allocPrint(self.allocator, "{s} FORMAT JSON", .{sql});
        defer self.allocator.free(full);
        const body = try self.runRaw(ctx.allocator, full);
        defer ctx.allocator.free(body);
        const rows = try parseRows(Type, ctx.allocator, body);
        if (rows.len == 0) return null;
        return rows[0];
    }

    pub fn queryRows(self: *ClickHouse, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        const sql = try self.interpolate(stmt, args);
        defer self.allocator.free(sql);
        const full = try std.fmt.allocPrint(self.allocator, "{s} FORMAT JSON", .{sql});
        defer self.allocator.free(full);
        const body = try self.runRaw(ctx.allocator, full);
        defer ctx.allocator.free(body);
        return try parseRows(Type, ctx.allocator, body);
    }

    pub fn queryRowContext(self: *ClickHouse, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) !?Type {
        return self.queryRow(ctx, Type, stmt, args);
    }

    pub fn queryRowsContext(self: *ClickHouse, ctx: *root.Context, comptime Type: type, comptime stmt: []const u8, args: anytype) ![]Type {
        return self.queryRows(ctx, Type, stmt, args);
    }

    pub fn selectSlice(self: *ClickHouse, ctx: *root.Context, comptime Type: type, list: *std.array_list.Managed(Type), comptime stmt: []const u8, args: anytype) !i64 {
        const rows = try self.queryRows(ctx, Type, stmt, args);
        for (rows) |r| try list.append(r);
        return @intCast(list.items.len);
    }

    /// Execute a write statement (INSERT/UPDATE/DDL). ClickHouse HTTP returns a
    /// summary, not a last-insert-id; we return 0 (eventually-consistent).
    pub fn execWithContext(self: *ClickHouse, ctx: *root.Context, comptime stmt: []const u8, args: anytype) !i64 {
        const sql = try self.interpolate(stmt, args);
        defer self.allocator.free(sql);
        _ = try self.runRaw(ctx.allocator, sql);
        return 0;
    }

    pub fn lastInsertRowID(self: *ClickHouse) i64 {
        _ = self;
        return 0;
    }

    pub fn rowsAffected(self: *ClickHouse) usize {
        _ = self;
        return 0;
    }

    /// ClickHouse has no transactions over its HTTP interface; these are no-ops
    /// (dialect-aware relaxation).
    pub fn begin(self: *ClickHouse) !void {
        _ = self;
    }

    pub fn commit(self: *ClickHouse) !void {
        _ = self;
    }

    pub fn rollback(self: *ClickHouse) void {
        _ = self;
    }

    /// Free the handle and its allocated strings. Call once the backend is no
    /// longer referenced (the persistent `zul` client is closed too).
    pub fn deinit(self: *ClickHouse, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.url);
        allocator.free(self.database);
        if (self.user) |u| allocator.free(u);
        if (self.password) |p| allocator.free(p);
        allocator.destroy(self);
    }
};

// ===================== Tests =====================

test "ClickHouse interpolates ? binds and escapes strings" {
    const alloc = std.testing.allocator;
    const ch = try ClickHouse.create(alloc, .{ .url = "http://localhost:8123" });
    defer ch.deinit(alloc);
    const sql = try ch.interpolate("SELECT * FROM t WHERE id = ? AND name = ?", .{ @as(i64, 1), "o'brien" });
    defer alloc.free(sql);
    try std.testing.expectEqualStrings("SELECT * FROM t WHERE id = 1 AND name = 'o''brien'", sql);

    const no_args = try ch.interpolate("SELECT 1", .{});
    defer alloc.free(no_args);
    try std.testing.expectEqualStrings("SELECT 1", no_args);
}

test "ClickHouse parses FORMAT JSON into a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const User = struct { id: i64, name: []const u8 };
    const body = "{\"meta\":[{\"name\":\"id\"},{\"name\":\"name\"}],\"data\":[{\"id\":1,\"name\":\"alice\"},{\"id\":2,\"name\":\"bob\"}],\"rows\":2}";
    const rows = try ClickHouse.parseRows(User, alloc, body);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].id);
    try std.testing.expectEqualStrings("alice", rows[0].name);
    try std.testing.expectEqual(@as(i64, 2), rows[1].id);
}

test "ClickHouse interpolate handles all arg types" {
    const alloc = std.testing.allocator;
    const ch = try ClickHouse.create(alloc, .{ .url = "http://localhost:8123" });
    defer ch.deinit(alloc);

    const a = try ch.interpolate("SELECT ? ? ?", .{ @as(i64, 7), @as(f64, 1.5), true });
    defer alloc.free(a);
    try std.testing.expectEqualStrings("SELECT 7 1.5 true", a);

    // null optional -> NULL
    const b = try ch.interpolate("WHERE x = ?", .{@as(?i64, null)});
    defer alloc.free(b);
    try std.testing.expectEqualStrings("WHERE x = NULL", b);

    // non-null optional -> inlined value
    const c = try ch.interpolate("WHERE x = ?", .{@as(?i64, 3)});
    defer alloc.free(c);
    try std.testing.expectEqualStrings("WHERE x = 3", c);

    // string literal (array pointer) escapes embedded quotes + trailing text
    const d = try ch.interpolate("name = ? AND active = 1", .{"o'brien"});
    defer alloc.free(d);
    try std.testing.expectEqualStrings("name = 'o''brien' AND active = 1", d);
}

test "ClickHouse relaxation returns no-op / zero" {
    const alloc = std.testing.allocator;
    const ch = try ClickHouse.create(alloc, .{ .url = "http://localhost:8123" });
    defer ch.deinit(alloc);
    try ch.begin();
    try ch.commit();
    ch.rollback();
    try std.testing.expectEqual(@as(i64, 0), ch.lastInsertRowID());
    try std.testing.expectEqual(@as(usize, 0), ch.rowsAffected());
}

test "ClickHouse parses empty FORMAT JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const User = struct { id: i64, name: []const u8 };
    const rows = try ClickHouse.parseRows(User, alloc, "{\"data\":[]}");
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
