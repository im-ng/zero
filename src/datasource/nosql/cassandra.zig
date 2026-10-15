const std = @import("std");
const root = @import("../../zero.zig");
const client = @import("cassandraClient.zig");

/// Cassandra wide-column backend. Talks the native CQL binary protocol v4 via the
/// self-contained `cassandraClient.zig` (no external driver dependency).
///
/// Unlike `SQL`, this backend does not build statements. Callers pass a full
/// CQL string to `get`/`put`/`delete`/`query`, so the query lives with the
/// caller (the route handler), never in the datasource layer. The configured
/// keyspace is `USE`d on connect, so statements need not qualify it.
pub const Cassandra = struct {
    conn: client.Connection,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        keyspace: []const u8,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
        tls_enabled: bool = false,
        tls_verify: bool = false,
        tls_ca_path: ?[]const u8 = null,
        tls_server_name: ?[]const u8 = null,
    }) !*Cassandra {
        // The connection owns `tls_ca_path`; dupe it so the config buffer's
        // lifetime does not constrain the connection.
        const tls_ca: ?[]u8 = if (opts.tls_ca_path) |p| try allocator.dupe(u8, p) else null;
        const tls_server_name: ?[]u8 = if (opts.tls_server_name) |p| try allocator.dupe(u8, p) else null;
        const self = try allocator.create(Cassandra);
        self.* = .{
            .conn = client.Connection.init(allocator, .{
                .contact_points = opts.contact_points,
                .user = opts.user orelse "cassandra",
                .pass = opts.password orelse "cassandra",
                .keyspace = opts.keyspace,
                .tls_enabled = opts.tls_enabled,
                .tls_verify = opts.tls_verify,
                .tls_ca_path = tls_ca,
                .tls_server_name = tls_server_name,
            }),
        };
        return self;
    }

    /// Run a SELECT-style `query` and return the first column of the first row,
    /// owned by `ctx.allocator`, or `null` when no row matches. Caller frees.
    pub fn get(self: *Cassandra, ctx: *root.Context, statement: []const u8) !?[]const u8 {
        var res = try self.conn.query(statement);
        defer res.deinit();
        if (res.rows.len == 0) return null;
        if (res.rows[0].cells.len == 0) return null;
        const cell = res.rows[0].cells[0];
        if (cell.data == null) return null;
        return try ctx.allocator.dupe(u8, cell.data.?);
    }

    /// Run an INSERT/UPDATE-style `query`. The result set is discarded.
    pub fn put(self: *Cassandra, _: *root.Context, statement: []const u8) !void {
        var res = try self.conn.query(statement);
        res.deinit();
    }

    /// Run a DELETE-style `query`. The result set is discarded.
    pub fn delete(self: *Cassandra, _: *root.Context, statement: []const u8) !void {
        var res = try self.conn.query(statement);
        res.deinit();
    }

    /// Run an arbitrary CQL `query` and return the rows as a JSON array, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn query(self: *Cassandra, ctx: *root.Context, statement: []const u8) ![]const u8 {
        var res = try self.conn.query(statement);
        defer res.deinit();
        return try res.toJson(ctx.allocator);
    }
};
