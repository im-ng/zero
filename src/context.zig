const std = @import("std");
const root = @import("zero.zig");
const httpz = root.httpz;
const zeroClient = root.client;
const pubSub = root.MQTT;
const mqMessage = root.mqMessage;
const Error = root.Error;
const Responder = root.responder;
const constants = root.constants;
const jwtClaims = root.jwtClaims;

pub const Context = struct {
    request: *httpz.Request = undefined,
    response: *httpz.Response = undefined,
    allocator: std.mem.Allocator = undefined,
    container: *root.container = undefined,

    SQL: *root.SQL = undefined,
    Cache: root.rediz.Client = undefined,
    MQ: *root.MQTT = undefined,
    provider: *root.AuthProvder = undefined,

    message: ?*mqMessage = null,

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

        if (container.SQL) |sql| {
            c.SQL = sql;
        }

        if (container.redis) |rdz| {
            c.Cache = rdz;
        }

        if (container.pubsub) |pb| {
            c.MQ = pb;
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

    /// returns if path param exist
    pub fn param(self: *Context, name: []const u8) []const u8 {
        const value = self.request.param(name);
        if (value == null) {
            return "";
        }

        return value.?;
    }
};
