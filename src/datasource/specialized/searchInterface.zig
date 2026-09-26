const std = @import("std");
const root = @import("../../zero.zig");
const service = root.circuit_breaker;
const utils = root.utils;

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
    metricz: ?*root.metricz = null,

    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker, metricz: ?*root.metricz) Search {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
            .metricz = metricz,
        };
    }

    fn backendName(b: Backend) []const u8 {
        return switch (b) {
            .solr => "solr",
            .mock => "mock",
        };
    }

    fn dsError(self: *Search, op: []const u8) void {
        var status: u16 = 0;
        if (self.lastError()) |d| status = d.status;
        if (self.metricz) |mz| {
            mz.datasourceError(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = status }) catch {};
        }
    }

    fn dsOk(self: *Search, op: []const u8, start: std.Io.Timestamp) void {
        if (self.metricz) |mz| {
            mz.datasourceResponse(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = 200 }, utils.elapsedMs(start)) catch {};
        }
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
        handle.* = Search.init(impl, backend, null, container.metricz);
        return handle;
    }

    /// Free the type-erased handle and the backend implementation it wraps. The
    /// backend owns any connections / duplicated config strings it allocated, so
    /// each branch tears down the impl before the handle struct is destroyed.
    pub fn deinit(self: *Search, allocator: std.mem.Allocator) void {
        switch (self.backend) {
            .solr => {
                const c = @as(*root.Solr, @ptrCast(@alignCast(self.ptr)));
                c.deinit(allocator);
            },
            .mock => {
                const mb = @as(*MockBackend, @ptrCast(@alignCast(self.ptr)));
                allocator.destroy(mb);
            },
        }
        allocator.destroy(self);
    }

    /// Index (upsert) a JSON document into `collection`.
    pub fn index(self: *Search, ctx: *root.Context, collection: []const u8, doc_json: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).index(ctx, collection, doc_json),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).index(ctx, collection, doc_json),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("index");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("index", start);
        return r;
    }

    /// Run a query against `collection` and return the JSON response body, owned
    /// by `ctx.allocator`. Caller frees.
    pub fn query(self: *Search, ctx: *root.Context, collection: []const u8, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, collection, q),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("query");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("query", start);
        return r;
    }

    /// Fetch a document by id from `collection`. Returns JSON body, owned by
    /// `ctx.allocator` (or `null` on 404). Caller frees.
    pub fn get(self: *Search, ctx: *root.Context, collection: []const u8, id: []const u8) !?[]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, id),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).get(ctx, collection, id),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("get");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("get", start);
        return r;
    }

    /// Delete a document by id from `collection`.
    pub fn delete(self: *Search, ctx: *root.Context, collection: []const u8, id: []const u8) !void {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, id),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).delete(ctx, collection, id),
        } catch |e| {
            if (self.breaker) |*b| b.recordFailure();
            self.dsError("delete");
            return e;
        };
        if (self.breaker) |*b| b.recordSuccess();
        self.dsOk("delete", start);
        return r;
    }

    /// Return the last upstream failure recorded by the backend, if any. Call
    /// Right after catching a `Solr*Failed` error, report the last failure
    /// class to the health probe. `lastError()` returns a *copy* of the
    /// status/`ErrorKind` (no shared heap buffer), so it is thread-safe to call
    /// from the probe while requests run concurrently.
    pub fn lastError(self: *Search) ?root.Error.DataSourceError {
        return switch (self.backend) {
            .solr => @as(*root.Solr, @ptrCast(@alignCast(self.ptr))).lastError(),
            .mock => null,
        };
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
    var s = Search.init(&mock, .mock, null, null);
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
