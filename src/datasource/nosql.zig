const std = @import("std");
const root = @import("../zero.zig");
const client = @import("cassandra_client.zig");

/// NoSQL wide-column backend. Talks the native CQL binary protocol v4 via the
/// self-contained `cassandra_client.zig` (no external driver dependency).
///
/// Unlike `SQL`, this backend does not build statements. Callers pass a full
/// CQL string to `get`/`put`/`delete`/`query`, so the query lives with the
/// caller (the route handler), never in the datasource layer. The configured
/// keyspace is `USE`d on connect, so statements need not qualify it.
pub const NoSQL = struct {
    conn: client.Connection,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        keyspace: []const u8,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
    }) !*NoSQL {
        const self = try allocator.create(NoSQL);
        self.* = .{
            .conn = client.Connection.init(
                allocator,
                opts.contact_points,
                opts.user orelse "cassandra",
                opts.password orelse "cassandra",
                opts.keyspace,
            ),
        };
        return self;
    }

    /// Run a SELECT-style `query` and return the first column of the first row,
    /// owned by `ctx.allocator`, or `null` when no row matches. Caller frees.
    pub fn get(self: *NoSQL, ctx: *root.Context, statement: []const u8) !?[]const u8 {
        var res = try self.conn.query(statement);
        defer res.deinit();
        if (res.rows.len == 0) return null;
        if (res.rows[0].cells.len == 0) return null;
        const cell = res.rows[0].cells[0];
        if (cell.data == null) return null;
        return try ctx.allocator.dupe(u8, cell.data.?);
    }

    /// Run an INSERT/UPDATE-style `query`. The result set is discarded.
    pub fn put(self: *NoSQL, _: *root.Context, statement: []const u8) !void {
        var res = try self.conn.query(statement);
        res.deinit();
    }

    /// Run a DELETE-style `query`. The result set is discarded.
    pub fn delete(self: *NoSQL, _: *root.Context, statement: []const u8) !void {
        var res = try self.conn.query(statement);
        res.deinit();
    }

    /// Run an arbitrary CQL `query` and return the rows as a JSON array, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn query(self: *NoSQL, ctx: *root.Context, statement: []const u8) ![]const u8 {
        var res = try self.conn.query(statement);
        defer res.deinit();
        return try res.toJson(ctx.allocator);
    }
};
