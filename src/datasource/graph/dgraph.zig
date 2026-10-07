const std = @import("std");
const root = @import("../../zero.zig");
const dgraphClient = @import("dgraphClient.zig");

/// Dgraph graph backend. Implements the unified `Graph` interface by delegating
/// to the self-contained `dgraphClient.Client` REST client (no external driver),
/// mirroring `search/meili.zig` / `search/meiliClient.zig`.
pub const Dgraph = struct {
    allocator: std.mem.Allocator,
    client: dgraphClient.Client,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        api_key: ?[]const u8 = null,
    }) !*Dgraph {
        const self = try allocator.create(Dgraph);
        self.* = .{
            .allocator = allocator,
            .client = dgraphClient.Client.init(allocator, .{
                .url = opts.url,
                .api_key = opts.api_key,
            }),
        };
        return self;
    }

    pub fn query(self: *Dgraph, ctx: *root.Context, q: []const u8) ![]const u8 {
        return self.client.query(ctx, q);
    }

    pub fn mutate(self: *Dgraph, ctx: *root.Context, m: []const u8) ![]const u8 {
        return self.client.mutate(ctx, m);
    }

    pub fn lastError(self: *Dgraph) ?root.Error.DataSourceError {
        return self.client.lastError();
    }

    /// Free the adapter and its underlying client.
    pub fn deinit(self: *Dgraph, allocator: std.mem.Allocator) void {
        self.client.deinit(allocator);
        allocator.destroy(self);
    }
};
