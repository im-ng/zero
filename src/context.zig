const std = @import("std");
const root = @import("zero.zig");
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

    SQL: root.Datasource = undefined,
    Cache: root.rediz.Client = undefined,
    provider: *root.AuthProvider = undefined,
    MQ: *root.MQTT = undefined,
    KF: *root.kafka = undefined,
    NATS: *root.nats = undefined,

    pubsub: *root.PubSub = undefined,
    message: ?root.pubsubInterface.Message = null,

    wsMessage: ?[]const u8 = null,
    wsClient: *root.httpz.websocket.Conn = undefined,
    action: *const fn (*root.Context) anyerror!void = undefined,

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
            .request = req,
            .response = res,
        };

        if (container.SQL != null or container.SQLite != null) {
            c.SQL = container.datasource;
        }

        if (container.redis) |rdz| {
            c.Cache = rdz;
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

        return c;
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
