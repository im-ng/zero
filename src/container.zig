const std = @import("std");
const root = @import("zero.zig");
const container = @This();
const Self = @This();

// internal
const pgz = root.pgz;
const constants = root.constants;
const Context = root.Context;
const Metricz = root.metricz;
const rediz = root.rediz;
const rdzClient = root.rediz.Client;
const rdzDatasource = root.rdz;
const zeroClient = root.client;
const MQTT = root.MQTT;
const mqConfig = root.mqConfig;

appName: []const u8 = undefined,
appVersion: []const u8 = undefined,
allocator: std.mem.Allocator,

log: *root.logger = undefined,
config: *root.config = undefined,
metricz: *root.metricz = undefined,
authProvider: *root.AuthProvder = undefined,

redis: ?rediz.Client = undefined,
rdz: ?*root.rdz = undefined,
SQL: ?*root.SQL = undefined,
services: ?std.StringHashMap(*zeroClient) = undefined,
pubsub: ?*root.MQTT = null,

pub fn create(self: Self) anyerror!*container {
    const c = try self.allocator.create(container);
    errdefer self.allocator.destroy(c);

    c.* = .{
        .allocator = self.allocator,
        .log = self.log,
        .config = self.config,
    };

    c.appName = c.config.getOrDefault(constants.APP_NAME, "zero");
    c.appVersion = c.config.getOrDefault(constants.APP_VERSION, "dev");

    // initialize service client handler maps
    c.services = std.StringHashMap(*zeroClient).init(self.allocator);

    // initialize metricz
    try c.loadMetricz();

    // initialize db
    try c.loadSQL();

    // initialize kv
    try c.loadRedis();

    // initilize message queues
    try c.loadPubSub();

    const msg: []const u8 = "container is created";
    c.log.info(msg);

    return c;
}

pub fn destroy(self: *Self) void {
    // recursively call internal sub containers to destroy themselves

    // self.allocator.destroy(metricz);

    // if (self.sql.* != null) {
    //     self.sql.deinit();
    // }
    // if (self.SQL) |sql| {
    //     self.allocator.destroy(sql);
    // }

    // if (self.redis != null) {
    //     self.allocator.destroy(&self.redis);
    // }

    // if (self.pubsub != null) {
    //     self.allocator.destroy(self.pubsub.?);
    // }

    // self.allocator.destroy(&self.log);

    const alloctor = self.allocator;
    alloctor.destroy(self);
}

fn loadPubSub(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.allocator.alloc(u8, 512);

    const pubsub = self.config.get("PUBSUB_BACKEND");
    if (std.mem.eql(u8, pubsub, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, pubsub, "MQTT") == false) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, not valid backend provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const hostname = self.config.get("MQTT_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as mqtt host is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const port = self.config.get("MQTT_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mqtt failed: mqtt port is empty.", .{});
        self.log.err(buffer);
        return;
    }

    // const protocol = self.config.getOrDefault("MQTT_PROTOCOL", "tcp");
    const username = self.config.getOrDefault("MQTT_USER", "");
    const password = self.config.getOrDefault("MQTT_PASSWORD", "");
    const clientID = self.config.getOrDefault("MQTT_CLIENT_ID_SUFFIX", "-none");
    // const keepalive = self.config.getAsBool("MQTT_KEEP_ALIVE");
    const portAsInt = try self.config.getAsInt("MQTT_PORT");
    const qos = try self.config.getAsInt("MQTT_QOS");
    const retain = self.config.getAsBool("MQTT_RETRIEVE_RETAINED");

    const config = &mqConfig{
        .clientID = clientID,
        .hostname = hostname,
        .ip = hostname,
        .username = username,
        .password = password,
        .keepAliveDuaration = 1,
        .qos = qos,
        .retainOnRetrieval = retain,
        .port = portAsInt,
        .connectionTimeout = 10_000,
    };

    buffer = try self.allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connecting to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    self.log.info(buffer);

    self.pubsub = MQTT.create(self, config) catch |err| {
        buffer = try self.allocator.alloc(u8, 256);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
        self.log.err(buffer);
        self.log.any(err);
        return;
    };

    if (self.pubsub) |pb| {
        try pb.mqtt.ping(.{});
    }

    buffer = try self.allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    self.log.info(buffer);
}

fn loadMetricz(self: *Self) !void {
    // initialize metrics
    self.metricz = try Metricz.initialize(self.allocator, .{ .prefix = "", .exclude = null });

    // app metrics
    try self.metricz.info(.{ .app_name = self.appName, .app_version = self.appVersion, .zero_version = "0.0.1" });

    try self.metricz.appThreads(.{ .label = "app_threads" }, 0);

    try self.metricz.appMemoryUsage(.{ .label = "app_memory_usage" }, 0);

    try self.metricz.appMemoryTotal(.{ .label = "app_memory_total" }, 0);

    // http metrics
    try self.metricz.response(.{ .path = "/", .method = "GET", .status = 200 }, 0);

    // redis metrics
    // todo

    // pub/sub metrics
    // todo

    // SQL metrics
    try self.metricz.sqlResponse(.{ .hostname = "", .database = "", .query = "", .operation = "select" }, 0);
}

fn loadRedis(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.allocator.alloc(u8, 512);

    const hostname = self.config.get("REDIS_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis is disabled, as redis host is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const port = self.config.get("REDIS_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database port is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const user = self.config.get("REDIS_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: user name is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const password = self.config.get("REDIS_PASSWORD");
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database password is empty.", .{});
        self.log.err(buffer);
        return;
    }

    const dbInt = try self.config.getAsInt("REDIS_DB");
    const portInt = try self.config.getAsInt("REDIS_PORT");

    const addr = try std.net.Address.parseIp4(hostname, portInt);
    const connection = try std.net.tcpConnectToAddress(addr);

    self.rdz = try rdzDatasource.create(self.allocator);

    self.redis = rdzClient.init(connection, .{
        .auth = .{
            .user = null,
            .pass = password,
        },
        .reader_buffer = &self.rdz.?.rbuf,
        .writer_buffer = &self.rdz.?.wbuf,
    }) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        std.posix.exit(1);
    };

    buffer = try std.fmt.bufPrint(buffer, "connecting to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    self.log.info(buffer);

    const ping = try self.redis.?.sendAlloc([]u8, self.allocator, .{"ping"});
    defer self.allocator.free(ping);

    buffer = try self.allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "ping status {s}", .{ping});
    self.log.info(buffer);

    buffer = try self.allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    self.log.info(buffer);
}

fn loadSQL(self: *Self) !void {
    var buffer: []u8 = undefined;
    buffer = try self.allocator.alloc(u8, 512);

    const dialect = self.config.get("DB_DIALECT");
    if (std.mem.eql(u8, dialect, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "database is disabled, as dialect is not provided.", .{});
        self.log.debug(buffer);
        return;
    }

    const hostname = self.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: host name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const port = self.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database port is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const user = self.config.get("DB_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: user name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const password = self.config.get("DB_PASSWORD");
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database password is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    const db = self.config.get("DB_NAME");
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database name is empty.", .{dialect});
        self.log.err(buffer);
        return;
    }

    var config = root.SQL.dbConfig{
        .databaseName = db,
        .dialect = dialect,
        .hostname = hostname,
        .port = port,
        .username = user,
        .password = password,
    };

    self.SQL = try root.SQL.create(
        self.allocator,
        &config,
        self.log,
        self.metricz,
    );

    const portInt = try self.config.getAsInt("DB_PORT");
    var options: pgz.Pool.Opts = .{
        .size = 10,
        .connect = .{
            .host = hostname,
            .port = portInt,
        },
        .auth = .{
            .application_name = self.config.get("APP_NAME"),
            .username = self.config.get("DB_USER"),
            .password = self.config.get("DB_PASSWORD"),
            .database = self.config.get("DB_NAME"),
            .timeout = 10_000, // load this from config
        },
    };

    self.SQL.?.sql = pgz.Pool.init(self.allocator, options) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        self.log.err(buffer);
        std.posix.exit(1);
    };
    self.SQL.?.options = &options;

    // reference metricz
    self.SQL.?.metricz = self.metricz;

    buffer = try std.fmt.bufPrint(buffer, "generating database connection string for {s}", .{dialect});
    self.log.info(buffer);

    buffer = try self.allocator.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to {s} user to {s} database at '{s}:{s}'", .{ user, db, hostname, port });
    self.log.info(buffer);
}

pub fn registerZeroClient(self: *Self, service: *zeroClient) !void {
    try self.services.?.put(service.name, service);
}
