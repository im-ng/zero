const std = @import("std");
const root = @import("../../zero.zig");
const meiliClient = @import("meiliClient.zig");

/// Meilisearch search backend. Implements the unified `Search` interface by
/// delegating to the self-contained `meiliClient.Client` REST client (no
/// external driver), mirroring `cassandra.zig` / `cassandraClient.zig`.
pub const Meili = struct {
    allocator: std.mem.Allocator,
    client: meiliClient.Client,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        url: []const u8,
        default_collection: []const u8,
        api_key: ?[]const u8 = null,
    }) !*Meili {
        const self = try allocator.create(Meili);
        self.* = .{
            .allocator = allocator,
            .client = meiliClient.Client.init(allocator, .{
                .url = opts.url,
                .default_collection = opts.default_collection,
                .api_key = opts.api_key,
            }),
        };
        return self;
    }

    pub fn index(self: *Meili, ctx: *root.Context, collection: []const u8, doc_json: []const u8) !void {
        return self.client.index(ctx, collection, doc_json);
    }

    pub fn query(self: *Meili, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        return self.client.search(ctx, collection, q);
    }

    pub fn get(self: *Meili, ctx: *root.Context, collection: []const u8, id: []const u8) !?[]const u8 {
        return self.client.getDocument(ctx, collection, id);
    }

    pub fn delete(self: *Meili, ctx: *root.Context, collection: []const u8, id: []const u8) !void {
        return self.client.deleteDocument(ctx, collection, id);
    }

    pub fn lastError(self: *Meili) ?root.Error.DataSourceError {
        return self.client.lastError();
    }

    /// Free the adapter and its underlying client.
    pub fn deinit(self: *Meili, allocator: std.mem.Allocator) void {
        self.client.deinit(allocator);
        allocator.destroy(self);
    }
};
