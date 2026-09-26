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
    // Last upstream failure, surfaced thread-safely via `lastError()`. The HTTP
    // status (always 0 here — MongoDB has no HTTP layer) and an `ErrorKind` are
    // stored atomically (no shared heap buffer), so concurrent requests and the
    // health probe read them without a lock or a use-after-free. Both reset at
    // the start of each call via `clearErr`.
    last_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    last_kind: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

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
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.ErrorKind.none), .monotonic);
    }

    fn setErr(self: *MongoDB, err: anyerror) !void {
        self.clearErr();
        self.last_status.store(0, .monotonic);
        self.last_kind.store(@intFromEnum(root.Error.classifyAnyError(err)), .monotonic);
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

    /// Thread-safe last-failure accessor. Returns `null` when the most recent
    /// attempt succeeded (or none has been made). `code` names the `ErrorKind`
    /// and `status` is always 0 for this non-HTTP backend. The returned struct
    /// is a copy with no shared heap buffer, so it is safe to read.
    pub fn lastError(self: *MongoDB) ?root.Error.DataSourceError {
        const kind = @as(root.Error.ErrorKind, @enumFromInt(self.last_kind.load(.monotonic)));
        if (kind == .none) return null;
        return .{
            .status = self.last_status.load(.monotonic),
            .code = @tagName(kind),
            .message = "",
        };
    }

    pub fn deinit(self: *MongoDB, allocator: std.mem.Allocator) void {
        self.clearErr();
        self.conn.deinit();
        allocator.free(self.db);
        allocator.destroy(self.conn);
        allocator.destroy(self);
    }
};
