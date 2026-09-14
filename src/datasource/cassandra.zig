const std = @import("std");
const root = @import("../zero.zig");
const client = @import("cassandra_client.zig");

/// Cassandra wide-column backend. Talks the native CQL binary protocol v4 via the
/// self-contained `cassandra_client.zig` (no external driver dependency). Key/value
/// semantics are projected onto a `(id text PRIMARY KEY, data text)` table per
/// collection inside the configured keyspace.
pub const Cassandra = struct {
    allocator: std.mem.Allocator,
    conn: client.Connection,
    keyspace: []const u8,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        keyspace: []const u8,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
    }) !*Cassandra {
        const self = try allocator.create(Cassandra);
        self.* = .{
            .allocator = allocator,
            .conn = client.Connection.init(
                allocator,
                opts.contact_points,
                opts.user orelse "cassandra",
                opts.password orelse "cassandra",
            ),
            .keyspace = try allocator.dupe(u8, opts.keyspace),
        };
        return self;
    }

    fn ensureTable(self: *Cassandra, collection: []const u8) !void {
        const stmt = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s}.{s} (id text PRIMARY KEY, data text)",
            .{ self.keyspace, collection },
        );
        defer self.allocator.free(stmt);
        var r = try self.conn.query(stmt);
        r.deinit();
    }

    pub fn get(self: *Cassandra, ctx: *root.Context, collection: []const u8, key: []const u8) !?[]const u8 {
        const q = try std.fmt.allocPrint(
            self.allocator,
            "SELECT data FROM {s}.{s} WHERE id = '{s}'",
            .{ self.keyspace, collection, key },
        );
        defer self.allocator.free(q);
        var res = try self.conn.query(q);
        defer res.deinit();
        if (res.rows.len == 0) return null;
        if (res.rows[0].cells.len == 0) return null;
        const cell = res.rows[0].cells[0];
        if (cell.data == null) return null;
        return try ctx.allocator.dupe(u8, cell.data.?);
    }

    pub fn put(self: *Cassandra, ctx: *root.Context, collection: []const u8, key: []const u8, value: []const u8) !void {
        try self.ensureTable(collection);
        const q = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s}.{s} (id, data) VALUES ('{s}', '{s}')",
            .{ self.keyspace, collection, key, value },
        );
        defer self.allocator.free(q);
        var r = try self.conn.query(q);
        r.deinit();
        _ = ctx;
    }

    pub fn delete(self: *Cassandra, _: *root.Context, collection: []const u8, key: []const u8) !void {
        const q = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM {s}.{s} WHERE id = '{s}'",
            .{ self.keyspace, collection, key },
        );
        defer self.allocator.free(q);
        var r = try self.conn.query(q);
        r.deinit();
    }

    pub fn query(self: *Cassandra, ctx: *root.Context, _: []const u8, q: []const u8) ![]const u8 {
        var res = try self.conn.query(q);
        defer res.deinit();
        return try res.toJson(ctx.allocator);
    }
};
