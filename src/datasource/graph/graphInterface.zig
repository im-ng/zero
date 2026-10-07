const std = @import("std");
const root = @import("../../zero.zig");
const service = root.circuit_breaker;
const utils = root.utils;

/// Graph database backends. Resolved at runtime from config so the same
/// type-erased `Graph` handle works for any configured backend. Add new
/// backends (Neptune, Neo4j, …) here and a case in the `switch`.
pub const Backend = enum {
    /// Dgraph graph database over its HTTP query/mutate API (`/_api` style
    /// `/query` + `/mutate`). Backed by `src/datasource/graph/dgraph.zig`.
    dgraph,
    /// Test-only backend backed by `MockBackend`. Lets the `Graph` dispatch be
    /// exercised without a running Dgraph.
    mock,
};

/// Connection options for a `Graph` backend.
pub const Options = struct {
    url: []const u8,
    /// Optional `X-Dgraph-AccessToken` (Dgraph Cloud / Enterprise auth).
    api_key: ?[]const u8 = null,
};

/// Unified, type-erased graph interface.
///
/// Usage (mirrors `ctx.Search` / `ctx.SQL`):
///   const res = try ctx.Graph.query(ctx, "query { me { name } }");
///   const res = try ctx.Graph.mutate(ctx, "{\"set\":[{\"name\":\"Alice\"}]}");
pub const Graph = struct {
    ptr: *anyopaque,
    backend: Backend,
    /// Optional circuit breaker guarding all backend calls. When `null`, calls
    /// pass straight through (no trip/fail-fast).
    breaker: ?service.CircuitBreaker = null,
    metricz: ?*root.metricz = null,

    /// Build an interface handle from a concrete backend pointer.
    pub fn init(ptr: anytype, backend: Backend, breaker: ?service.CircuitBreaker, metricz: ?*root.metricz) Graph {
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .backend = backend,
            .breaker = breaker,
            .metricz = metricz,
        };
    }

    fn backendName(b: Backend) []const u8 {
        return switch (b) {
            .dgraph => "dgraph",
            .mock => "mock",
        };
    }

    fn dsError(self: *Graph, op: []const u8) void {
        var status: u16 = 0;
        if (self.lastError()) |d| status = d.status;
        if (self.metricz) |mz| {
            mz.datasourceError(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = status }) catch {};
        }
    }

    fn dsOk(self: *Graph, op: []const u8, start: std.Io.Timestamp) void {
        if (self.metricz) |mz| {
            mz.datasourceResponse(.{ .backend = backendName(self.backend), .name = "", .operation = op, .status = 200 }, utils.elapsedMs(start)) catch {};
        }
    }

    /// Construct a fully wired handle from backend + options.
    pub fn build(container: *root.container, backend: Backend, opts: Options) !*Graph {
        const impl: *anyopaque = switch (backend) {
            .dgraph => blk: {
                const c = try root.Dgraph.create(container.allocator, .{
                    .url = opts.url,
                    .api_key = opts.api_key,
                });
                break :blk @as(*anyopaque, c);
            },
            .mock => blk: {
                const mb = try container.allocator.create(MockBackend);
                mb.* = MockBackend{};
                break :blk @as(*anyopaque, mb);
            },
        };
        const handle = try container.allocator.create(Graph);
        handle.* = Graph.init(impl, backend, null, container.metricz);
        return handle;
    }

    /// Run a query (GraphQL or DQL) and return the raw response body, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn query(self: *Graph, ctx: *root.Context, q: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .dgraph => @as(*root.Dgraph, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).query(ctx, q),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("query");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("query", start);
        return r;
    }

    /// Run a mutation (JSON/RDF) and return the raw response body, owned by
    /// `ctx.allocator`. Caller frees.
    pub fn mutate(self: *Graph, ctx: *root.Context, m: []const u8) ![]const u8 {
        if (self.breaker) |*b| b.before() catch return error.CircuitOpen;
        const start = utils.nowMonotonic();
        const r = switch (self.backend) {
            .dgraph => @as(*root.Dgraph, @ptrCast(@alignCast(self.ptr))).mutate(ctx, m),
            .mock => @as(*MockBackend, @ptrCast(@alignCast(self.ptr))).mutate(ctx, m),
        } catch |e| {
            if (self.breaker) |*b| {
                b.recordFailure();
            }
            self.dsError("mutate");
            return e;
        };
        if (self.breaker) |*b| {
            b.recordSuccess();
        }
        self.dsOk("mutate", start);
        return r;
    }

    /// Right after catching an error, report the last failure class to the
    /// health probe. Returns a *copy* of the status/`ErrorKind` (no shared heap
    /// buffer), so it is thread-safe to call from the probe.
    pub fn lastError(self: *Graph) ?root.Error.DataSourceError {
        return switch (self.backend) {
            .dgraph => @as(*root.Dgraph, @ptrCast(@alignCast(self.ptr))).lastError(),
            .mock => null,
        };
    }

    /// Free the backend impl and the type-erased handle.
    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        switch (self.backend) {
            .dgraph => @as(*root.Dgraph, @ptrCast(@alignCast(self.ptr))).deinit(allocator),
            .mock => allocator.destroy(@as(*MockBackend, @ptrCast(@alignCast(self.ptr)))),
        }
        allocator.destroy(self);
    }
};

/// Native-free backend used by tests to verify `Graph` dispatch without a
/// running Dgraph.
pub const MockBackend = struct {
    queries: u32 = 0,
    mutations: u32 = 0,

    pub fn query(self: *MockBackend, _: *root.Context, _: []const u8) ![]const u8 {
        self.queries += 1;
        return "";
    }

    pub fn mutate(self: *MockBackend, _: *root.Context, _: []const u8) ![]const u8 {
        self.mutations += 1;
        return "";
    }
};
