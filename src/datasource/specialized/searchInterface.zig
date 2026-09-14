const std = @import("std");
const root = @import("../../zero.zig");
const service = root.circuit_breaker;

/// Search backends. Resolved at runtime from config so the same type-erased
/// `Search` handle works for any configured backend. Add new backends
/// (Elasticsearch, Meilisearch, …) here and a case in the `switch`.
pub const Backend = enum {
    solr,
    /// Test-only backend backed by `MockBackend`. Lets the `Search` dispatch be
    /// exercised without a running Solr.
    mock,
};

/// Connection options for a `Search` backend.
pub const Options = struct {
    url: []const u8,
    /// Default collection / core used when a call omits `collection`.
    default_collection: []const u8,
    /// Optional `?auth_user=...&auth_pass=...` style — left as a raw header here.
    basic_auth: ?[]const u8 = null,
};

/// Unified, type-erased search interface.
///
/// Usage (mirrors `ctx.SQL`):
///   try ctx.Search.index(ctx, "products", "{\"id\":\"1\",\"title\":\"shoe\"}");
///   const hits = try ctx.Search.query(ctx, "products", "title:shoe");
pub const Search = struct {
    ptr: *anyopaque,
    backend: Backend,
    breaker: ?service.CircuitBreaker = null,

    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker) Search {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
        };
    }

    pub fn build(container: *root.container, backend: Backend, opts: Options) !*Search {
        const impl: *anyopaque = switch (backend) {
            .solr => blk: {
                const c = try root.Solr.create(container.allocator, .{
                    .url = opts.url,
                    .default_collection = opts.default_collection,
                    .basic_auth = opts.basic_auth,
                });
                break :blk @as(*anyopaque, c);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{ .last_doc = "" };
                break :blk @as(*anyopaque, mb);
            },
        };
        const handle = try container.allocator.create(Search);
        handle.* = Search.init(impl, backend, null);
        return handle;
    }

    /// Index (upsert) a JSON document into `collection`.
    pub fn index(self: *Search, ctx: *root.Context, collection: []const u8, doc_json: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).index(ctx, collection, doc_json),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).index(ctx, collection, doc_json),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Run a query against `collection` and return the JSON response body, owned
    /// by `ctx.allocator`. Caller frees.
    pub fn query(self: *Search, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Fetch a document by id from `collection`. Returns JSON body, owned by
    /// `ctx.allocator` (or `null` on 404). Caller frees.
    pub fn get(self: *Search, ctx: *root.Context, collection: []const u8, id: []const u8) !?[]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, id),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, id),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }

    /// Delete a document by id from `collection`.
    pub fn delete(self: *Search, ctx: *root.Context, collection: []const u8, id: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, id),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, id),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        return r;
    }
};

/// Native-free backend used by tests to verify `Search` dispatch without a
/// running Solr.
pub const MockBackend = struct {
    indexes: u32 = 0,
    queries: u32 = 0,
    last_doc: []const u8,

    pub fn index(self: *MockBackend, _: *root.Context, _: []const u8, doc_json: []const u8) !void {
        self.indexes += 1;
        self.last_doc = doc_json;
    }

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }

    pub fn get(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) !?[]const u8 {
        _ = self;
        return null;
    }

    pub fn delete(self: *MockBackend, _: *root.Context, _: []const u8, _: []const u8) !void {
        _ = self;
    }
};


// ===================== Tests =====================


test "Search dispatches through the type-erased handle" {
    var mock: MockBackend = .{ .last_doc = "" };
    var s = Search.init(&mock, .mock, null);
    var ctx_storage: root.Context = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ctx_storage.allocator = arena.allocator();

    try s.index(&ctx_storage, "products", "{\"id\":\"1\"}");
    try std.testing.expectEqual(@as(u32, 1), mock.indexes);
    try std.testing.expectEqualStrings("{\"id\":\"1\"}", mock.last_doc);

    _ = try s.query(&ctx_storage, "products", "title:shoe");
    try std.testing.expectEqual(@as(u32, 1), mock.queries);

    const got = try s.get(&ctx_storage, "products", "1");
    try std.testing.expect(got == null);
}
