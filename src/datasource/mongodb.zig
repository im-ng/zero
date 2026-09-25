const std = @import("std");
const root = @import("../zero.zig");
const client = @import("mongodb_client.zig");

/// MongoDB document backend over the pure-Zig `mongodb_client.zig` wire protocol
/// (OP_MSG + SCRAM-SHA-256, optional TLS). Exposes the same `get`/`put`/`delete`/
/// `query` surface as the Cassandra backend; `statement` is a JSON MongoDB command
/// (the caller supplies the full command, matching the NoSQL full-statement model).
pub const MongoDB = struct {
    allocator: std.mem.Allocator,
    conn: *client.Connection,
    db: []const u8,
    // Last upstream failure, read by the caller right after catching the bare
    // error. `message` is owned by `allocator`.
    last_error: ?root.Error.DataSourceError = null,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        user: []const u8 = "",
        pass: []const u8 = "",
        auth_source: []const u8 = "admin",
        db: []const u8,
        tls_enabled: bool = false,
        tls_verify: bool = false,
        tls_ca_path: ?[]const u8 = null,
    }) !*MongoDB {
        const self = try allocator.create(MongoDB);
        self.* = .{
            .allocator = allocator,
            .conn = try allocator.create(client.Connection),
            .db = try allocator.dupe(u8, opts.db),
        };
        self.conn.* = client.Connection.init(allocator, .{
            .contact_points = try allocator.dupe(u8, opts.contact_points),
            .user = try allocator.dupe(u8, opts.user),
            .pass = try allocator.dupe(u8, opts.pass),
            .auth_source = try allocator.dupe(u8, opts.auth_source),
            .db = try allocator.dupe(u8, opts.db),
            .tls_enabled = opts.tls_enabled,
            .tls_verify = opts.tls_verify,
            .tls_ca_path = if (opts.tls_ca_path) |p| try allocator.dupe(u8, p) else null,
        });
        return self;
    }

    fn clearErr(self: *MongoDB) void {
        if (self.last_error) |e| {
            self.allocator.free(e.message);
            self.last_error = null;
        }
    }

    fn setErr(self: *MongoDB, err: anyerror) !void {
        self.clearErr();
        self.last_error = .{ .status = 0, .message = try self.allocator.dupe(u8, @errorName(err)) };
    }

    fn run(self: *MongoDB, ctx: *root.Context, statement: []const u8) ![]const u8 {
        self.clearErr();
        return self.conn.runCommand(ctx.allocator, self.db, statement) catch |e| {
            self.setErr(e) catch {};
            return e;
        };
    }

    pub fn get(self: *MongoDB, ctx: *root.Context, statement: []const u8) !?[]const u8 {
        const json = try self.run(ctx, statement);
        return json;
    }

    pub fn put(self: *MongoDB, ctx: *root.Context, statement: []const u8) !void {
        _ = try self.run(ctx, statement);
    }

    pub fn delete(self: *MongoDB, ctx: *root.Context, statement: []const u8) !void {
        _ = try self.run(ctx, statement);
    }

    pub fn query(self: *MongoDB, ctx: *root.Context, statement: []const u8) ![]const u8 {
        return try self.run(ctx, statement);
    }

    pub fn deinit(self: *MongoDB, allocator: std.mem.Allocator) void {
        self.clearErr();
        self.conn.deinit();
        allocator.free(self.db);
        allocator.destroy(self.conn);
        allocator.destroy(self);
    }
};
