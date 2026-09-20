const std = @import("std");
const root = @import("zero.zig");
const otel = root.otel;
const httpz = root.httpz;
const zeroClient = root.client;
const pubSub = root.MQTT;
const mqMessage = root.mqMessage;
const natsMessage = root.natsMessage;
const Error = root.Error;
const Responder = root.responder;
const constants = root.constants;
const jwtClaims = root.jwtClaims;
const kafka = root.kafka;
const kafkaMessage = root.kafkaMessage;
const gql = @import("graphql.zig");

pub const Context = struct {
    request: *httpz.Request = undefined,
    response: *httpz.Response = undefined,
    allocator: std.mem.Allocator = undefined,
    container: *root.container = undefined,
    io: std.Io = undefined,

    SQL: root.Datasource = undefined,
    KV: ?*root.KVStore = null,
    FileStore: ?*root.FileStore = null,
    Timeseries: ?*root.Timeseries = null,
    Search: ?*root.Search = null,
    NoSQL: ?*root.NoSQL = null,
    provider: *root.AuthProvider = undefined,
    MQ: *root.MQTT = undefined,
    KF: *root.kafka = undefined,
    NATS: *root.nats = undefined,

    pubsub: *root.PubSub = undefined,
    message: ?root.pubsubInterface.Message = null,

    wsMessage: ?[]const u8 = null,
    wsClient: *root.httpz.websocket.Conn = undefined,
    action: *const fn (*root.Context) anyerror!void = undefined,

    /// CLI command parameters parsed from argv (e.g. `--name John` -> "John").
    params: std.StringHashMap([]const u8) = undefined,

    /// Active OpenTelemetry span for this request (set by the `tracz` middleware
    /// before dispatch). Null when OTEL_EXPERIMENTAL is off or outside a request.
    otel_span: ?otel.ActiveSpan = null,

    /// initialize context
    pub fn init(
        allocator: std.mem.Allocator,
        container: *root.container,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !Context {
        var c = Context{
            .allocator = allocator,
            .container = container,
            .io = container.io,
            .request = req,
            .response = res,
        };

        if (container.SQL != null) {
            // Postgres/MySQL: hand each request its own session that borrows the
            // shared (thread-safe) connection pool but isolates transaction_conn
            // /lastId/rows so concurrent requests can't share a transaction or
            // clobber each other's last-insert-id.
            const session = try root.SQL.createSession(allocator, container.SQL.?);
            c.SQL = root.Datasource.init(session, .postgres, container.datasource.breaker);
        } else if (container.SQLite != null or container.DuckDB != null) {
            // SQLite/DuckDB backends reuse a single shared connection; the
            // per-request session does not apply (see ZIG_LEARNINGS.md — their
            // single-connection concurrency is a separate, documented limitation).
            c.SQL = container.datasource;
        }

        if (container.defaultKV) |kv| {
            c.KV = kv;
        }

        if (container.Timeseries) |ts| {
            c.Timeseries = ts;
        }

        if (container.Search) |s| {
            c.Search = s;
        }

        if (container.NoSQL) |n| {
            c.NoSQL = n;
        }

        if (container.defaultFileStore) |fs| {
            c.FileStore = fs;
        }

        if (container.mqtt) |pb| {
            c.MQ = pb;
        }

        if (container.Kakfa) |k| {
            c.KF = k;
        }

        if (container.Nats) |n| {
            c.NATS = n;
        }

        if (container.pubSub) |ps| {
            c.pubsub = ps;
        }

        c.otel_span = otel.currentSpan();

        return c;
    }

    /// Initialize a context for CLI / non-HTTP use. Derives the same datasource
    /// handles as `init` but requires no httpz Request/Response.
    pub fn initCli(allocator: std.mem.Allocator, container: *root.container) !Context {
        var c = Context{
            .allocator = allocator,
            .container = container,
            .io = container.io,
            .params = std.StringHashMap([]const u8).init(allocator),
        };

        if (container.SQL != null or container.SQLite != null or container.DuckDB != null) {
            c.SQL = container.datasource;
        }
        if (container.defaultKV) |kv| c.KV = kv;
        if (container.Timeseries) |ts| c.Timeseries = ts;
        if (container.Search) |s| c.Search = s;
        if (container.NoSQL) |n| c.NoSQL = n;
        if (container.defaultFileStore) |fs| c.FileStore = fs;
        if (container.mqtt) |pb| c.MQ = pb;
        if (container.Kakfa) |k| c.KF = k;
        if (container.Nats) |n| c.NATS = n;
        if (container.pubSub) |ps| c.pubsub = ps;

        return c;
    }

    /// Get a parsed CLI flag value (e.g. `--name John` -> Param("name") == "John").
    pub fn Param(self: *Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Print to stdout without a trailing newline.
    pub fn print(self: *Context, comptime fmt: []const u8, args: anytype) void {
        const out = std.Io.File.stdout();
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        out.writeStreamingAll(self.io, msg) catch {};
    }

    /// Print a line to stdout.
    pub fn println(self: *Context, comptime fmt: []const u8, args: anytype) void {
        self.print(fmt, args);
        const out = std.Io.File.stdout();
        out.writeStreamingAll(self.io, "\n") catch {};
    }

    /// Access the framework logger.
    pub fn Logger(self: *Context) *root.logger {
        return self.container.log;
    }

    /// log debug message through context allocator
    pub fn debug(self: *Context, message: []const u8) void {
        self.container.log.Debug(self.allocator, message);
    }

    /// log info message through context allocator
    pub fn info(self: *Context, message: []const u8) void {
        self.container.log.Info(self.allocator, message);
    }

    /// log info message of anytype through context allocator
    pub fn any(self: *Context, message: anytype) void {
        self.container.log.Any(self.allocator, message);
    }

    /// log error message through context allocator
    pub fn err(self: *Context, message: []const u8) void {
        self.container.log.Err(self.allocator, message);
    }

    /// log warn message through context allocator
    pub fn warn(self: *Context, message: []const u8) void {
        self.container.log.Warn(self.allocator, message);
    }

    /// log fatal message through context allocator
    pub fn fatal(self: *Context, message: []const u8) void {
        self.container.log.Fatal(self.allocator, message);
    }

    /// deinit context from parent allocator
    pub fn deinit(self: *Context) void {
        self.allocator.destroy(self);
    }

    /// returns traceID of the service request
    pub fn trace(self: *Context) ?[]const u8 {
        return self.request.headers.get("X-Correlation-ID");
    }

    /// returns correlationID of the request
    pub fn getCorrelationID(self: *Context) ?[]const u8 {
        return self.request.headers.get("X-Correlation-ID");
    }

    /// Returns the active OpenTelemetry span handle for this request, or null when
    /// OTEL_EXPERIMENTAL is off or outside a request context.
    pub fn span(self: *Context) ?otel.ActiveSpan {
        return self.otel_span;
    }

    /// Start a child span parented to the active request span. Returns the span
    /// (or null when OTel is disabled). Caller must `defer span.deinit()` and
    /// call `ctx.endSpan(&span)` when the work completes.
    pub fn startChildSpan(self: *Context, name: []const u8) !?otel.Span {
        return self.container.otel.startChildSpan(self.allocator, name, .Internal);
    }

    /// End a span started via `startChildSpan` (runs processors/exporters).
    pub fn endSpan(self: *Context, sp: *otel.Span) void {
        self.container.otel.endSpan(sp);
    }

    /// returns basic auth username claim
    pub fn getUsername(self: *Context) !?[]const u8 {
        return try self.container.authProvider.retrieveUserName(
            self.allocator,
            self.request.header(constants.AUTH_HEADER).?,
        );
    }

    /// returns basic auth claim
    pub fn getAuthClaims(self: *Context) !?jwtClaims {
        return try self.container.authProvider.retrieveClaims(
            self.allocator,
            self.request.header(constants.AUTH_HEADER).?,
        );
    }

    /// returns api key claim
    pub fn getAuthKey(self: *Context) !?[]const u8 {
        return self.request.header(constants.APIKEY_HEADER).?;
    }

    /// returns registered http service
    pub fn getService(self: *Context, svc: []const u8) ?*zeroClient {
        return self.container.services.?.get(svc);
    }

    /// Look up a named KV store registered via `App.addKVStore`. The default
    /// store (e.g. Redis when configured) is also available as `ctx.KV`.
    pub fn GetKVStore(self: *Context, name: []const u8) ?*root.KVStore {
        return self.container.kvStores.get(name);
    }

    /// Look up a named file store registered via `App.addFileStore`. The default
    /// store (the `local` backend when `FILE_STORE_ROOT` is configured) is also
    /// available as `ctx.FileStore`.
    pub fn GetFileStore(self: *Context, name: []const u8) ?*root.FileStore {
        return self.container.fileStores.get(name);
    }

    /// Returns an uploaded file from a `multipart/form-data` request, or `null`
    /// if no field with that name was submitted. The `data` slice is valid only
    /// for the lifetime of the request (arena-owned) — copy it to persist.
    pub fn GetFile(self: *Context, field: []const u8) !?root.UploadedFile {
        const form = try self.request.multiFormData();
        const f = form.get(field) orelse return null;
        return root.UploadedFile{
            .data = f.value,
            .filename = f.filename orelse "",
            .size = f.value.len,
        };
    }

    /// Streams a local file to the client as a download, setting
    /// `Content-Type` (from the extension) and a `Content-Disposition`
    /// attachment header. The file contents are allocated with `ctx.allocator`.
    pub fn File(self: *Context, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var rbuf: [8192]u8 = undefined;
        var reader = file.reader(self.io, &rbuf);
        const data = try reader.interface.allocRemainingAlignedSentinel(
            self.allocator,
            std.Io.Limit.limited(constants.DEFAULT_REQUEST_BODY_LIMIT_BYTES),
            std.mem.Alignment.@"1",
            null,
        );
        self.response.header("content-type", mimeForPath(path));
        const name = std.fs.path.basename(path);
        const disp = try std.fmt.allocPrint(
            self.allocator,
            "attachment; filename=\"{s}\"",
            .{name},
        );
        self.response.header("content-disposition", disp);
        self.response.setStatus(.ok);
        // Write the body through the response writer (not `response.body`): the
        // returned slice is request-arena owned and would be freed before httpz
        // flushes `response.body` to the socket.
        const w = self.response.writer();
        try w.writeAll(data);
    }

    /// Reads a file from a named file store. The returned slice is allocated
    /// from the request arena and is valid for the lifetime of the handler (it is
    /// freed when the request ends) — assign it to `ctx.response.body` directly
    /// rather than freeing it yourself.
    pub fn GetFileFromStore(self: *Context, name: []const u8, key: []const u8) !?[]const u8 {
        const store = self.GetFileStore(name) orelse return error.FileStoreNotFound;
        return try store.get(self, key);
    }

    /// Writes `data` to a named file store under `key`.
    pub fn SaveFileToStore(self: *Context, name: []const u8, key: []const u8, data: []const u8) !void {
        const store = self.GetFileStore(name) orelse return error.FileStoreNotFound;
        try store.create(self, key, data);
    }

    /// Deletes `key` from a named file store.
    pub fn DeleteFileFromStore(self: *Context, name: []const u8, key: []const u8) !void {
        const store = self.GetFileStore(name) orelse return error.FileStoreNotFound;
        try store.delete(self, key);
    }

    fn mimeForPath(path: []const u8) []const u8 {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return "application/octet-stream";
        const map = [_]struct { ext: []const u8, mime: []const u8 }{
            .{ .ext = ".txt", .mime = "text/plain" },
            .{ .ext = ".html", .mime = "text/html" },
            .{ .ext = ".htm", .mime = "text/html" },
            .{ .ext = ".css", .mime = "text/css" },
            .{ .ext = ".js", .mime = "application/javascript" },
            .{ .ext = ".json", .mime = "application/json" },
            .{ .ext = ".csv", .mime = "text/csv" },
            .{ .ext = ".png", .mime = "image/png" },
            .{ .ext = ".jpg", .mime = "image/jpeg" },
            .{ .ext = ".jpeg", .mime = "image/jpeg" },
            .{ .ext = ".gif", .mime = "image/gif" },
            .{ .ext = ".webp", .mime = "image/webp" },
            .{ .ext = ".svg", .mime = "image/svg+xml" },
            .{ .ext = ".pdf", .mime = "application/pdf" },
            .{ .ext = ".zip", .mime = "application/zip" },
            .{ .ext = ".xml", .mime = "application/xml" },
            .{ .ext = ".bin", .mime = "application/octet-stream" },
        };
        for (map) |m| {
            if (std.ascii.eqlIgnoreCase(m.ext, ext)) return m.mime;
        }
        return "application/octet-stream";
    }

    /// checks availability of the pubsub service
    pub fn getPubSubAvailability(self: *Context) bool {
        if (self.container.pubsub == null) {
            return false;
        }
        return true;
    }

    /// retrieves registered pubsub client
    pub fn getPublisher(self: *Context) *pubSub {
        if (self.container.pubsub == null) {
            self.container.log.Err(self.allocator, "no mqtt client initilized");
            return;
        }
        return self.container.pubsub.?;
    }

    /// retrieve registered pubsub subscriber client
    pub fn getSubscriber(self: *Context) !*pubSub {
        if (self.container.pubsub == null) {
            self.container.log.Err(self.allocator, "no mqtt client initilized");
            return;
        }
        return self.container.pubsub.?;
    }

    /// packs response in custom json to respond
    pub fn json(self: *Context, data: anytype) !void {
        self.response.setStatus(.ok);
        try self.response.json(.{
            .data = data,
        }, .{});
    }

    /// Issues a 3xx redirect. Defaults to 302 Found; use redirectWith for an
    /// explicit status (e.g. .moved_permanently / .see_other / .temporary_redirect).
    pub fn redirect(self: *Context, url: []const u8) void {
        self.redirectWith(std.http.Status.found, url);
    }

    pub fn redirectWith(self: *Context, status: std.http.Status, url: []const u8) void {
        self.response.setStatus(status);
        self.response.header("Location", url);
    }

    /// transforms incoming request json to comptime type
    pub fn bind(self: *Context, comptime T: type) !?T {
        const b = self.request.body() orelse return null;
        return try std.json.parseFromSliceLeaky(T, self.allocator, b, .{ .ignore_unknown_fields = true });
    }

    /// transforms an incoming protobuf request body (application/x-protobuf) into
    /// the comptime type `T` (a generated protobuf message exposing `decode`).
    /// Decoding uses the per-request arena allocator, released at request end.
    pub fn bindProto(self: *Context, comptime T: type) !?T {
        const b = self.request.body() orelse return null;
        var reader: std.Io.Reader = .fixed(b);
        return try T.decode(&reader, self.allocator);
    }

    /// serializes `data` (a protobuf message exposing `encode`) into the response
    /// body with `Content-Type: application/x-protobuf`.
    pub fn protobuf(self: *Context, data: anytype) !void {
        var w: std.Io.Writer.Allocating = .init(self.allocator);
        try data.encode(&w.writer, self.allocator);
        self.response.body = w.written();
        self.response.header("content-type", "application/x-protobuf");
        self.response.setStatus(.ok);
    }

    /// writes a raw, already-serialized XML string to the response with
    /// `Content-Type: application/xml`. The caller owns `body` (it is copied
    /// into the response buffer immediately via the writer, so arena-backed
    /// memory is safe to pass).
    pub fn xml(self: *Context, body: []const u8) !void {
        self.response.setStatus(.ok);
        self.response.header("content-type", "application/xml");
        try self.response.writer().writeAll(body);
    }

    /// Executes a GraphQL query against the given resolver root(s) and writes a
    /// `Content-Type: application/json` `{ data, errors }` response.
    ///
    /// `mutation_root` may be null when the operation is always a query.
    pub fn graphql(
        self: *Context,
        comptime Query: type,
        comptime Mutation: ?type,
        query_root: *const Query,
        mutation_root: ?*const anyopaque,
    ) !void {
        try gql.handle(self, Query, Mutation, query_root, mutation_root);
    }

    /// returns if path param exist
    pub fn param(self: *Context, name: []const u8) []const u8 {
        const value = self.request.param(name);
        if (value == null) {
            return "";
        }

        return value.?;
    }
};


// ===================== Tests =====================


test "context: protobuf bindProto and protobuf round-trip" {
    const protobuf = @import("protobuf");
    const t = httpz.testing;

    // A minimal protobuf message described entirely via the generic
    // protobuf.encode/decode primitives (no generated code needed here).
    const TestMsg = struct {
        value: []const u8 = &.{},

        pub const _desc_table = .{
            .value = protobuf.fd(1, .{ .scalar = .string }),
        };

        pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
            return protobuf.encode(writer, allocator, self);
        }
        pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) !@This() {
            return protobuf.decode(@This(), reader, allocator);
        }
    };

    var testing = t.init(.{});
    defer testing.deinit();

    // Encode a TestMsg into protobuf bytes.
    const msg = TestMsg{ .value = "hello protobuf" };
    var w: std.Io.Writer.Allocating = .init(testing.arena);
    try msg.encode(&w.writer, testing.arena);
    const encoded = w.written();

    // Put the encoded bytes on the request body.
    testing.body(encoded);

    // Build a Context over the mocked request/response.
    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    // bindProto decodes the body.
    const decoded = (try ctx.bindProto(TestMsg)).?;
    try std.testing.expectEqualStrings("hello protobuf", decoded.value);

    // protobuf serializes back into the response.
    try ctx.protobuf(decoded);
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-type", "application/x-protobuf");
    try testing.expectBody(encoded);
}

test "context: xml writes application/xml body" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try ctx.xml("<note><to>Zero</to></note>");
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-type", "application/xml");
    try testing.expectBody("<note><to>Zero</to></note>");
}

test "context: GetFile parses a multipart upload" {
    const t = httpz.testing;
    var testing = t.init(.{ .request = .{ .max_multiform_count = 5 } });
    defer testing.deinit();

    const body =
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "\r\n" ++
        "hello file\r\n" ++
        "--BOUND--\r\n";
    testing.header("content-type", "multipart/form-data; boundary=BOUND");
    testing.body(body);

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.request = testing.req;
    ctx.response = testing.res;

    const f = (try ctx.GetFile("file")).?;
    try std.testing.expectEqualStrings("a.txt", f.filename);
    try std.testing.expectEqualStrings("hello file", f.data);
    try std.testing.expectEqual(@as(usize, 10), f.size);
}

test "context: File serves a local file as a download" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    const dir = ".ztmp-filestore-ctx";
    defer std.Io.Dir.cwd().deleteTree(root.utils.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(root.utils.io, dir);
    const path = try std.fmt.allocPrint(testing.arena, "{s}/serve.txt", .{dir});
    const fh = try std.Io.Dir.cwd().createFile(root.utils.io, path, .{});
    defer fh.close(root.utils.io);
    try fh.writeStreamingAll(root.utils.io, "download me");

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.io = std.testing.io;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try ctx.File(path);
    try testing.expectStatusCode(.ok);
    try testing.expectHeader("content-disposition", "attachment; filename=\"serve.txt\"");
    try testing.expectHeader("content-type", "text/plain");
    try testing.expectBody("download me");
}
