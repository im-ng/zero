const std = @import("std");
const root = @import("zero.zig");
const App = @This();
const Self = @This();
const httpz = root.httpz;
const Context = root.Context;
const constants = root.constants;
const utils = root.utils;
const migration = root.migration;
const migrate = root.migrate;
const zeroClient = root.client;
const Cronz = root.cronz;
const AuthProvider = root.AuthProvder;
const favoriteIcon = root.favIcon;

pub const indexCss = root.indexCss;
pub const indexHtml = root.indexHtml;
pub const oauthRedirect = root.oauthRedirect;
pub const oauthRedirectJs = root.oauthRedirectJs;
pub const swaggerInitializerJs = root.swaggerInitializerJs;
pub const swaggerUIBundle = root.swaggerUIBundle;
pub const swaggerUIBundlerPreset = root.swaggerUIBundlerPreset;
pub const swaggerUICss = root.swaggerUICss;
pub const swaggerUIJs = root.swaggerUIJs;

log: *root.logger = undefined,
config: *root.config = undefined,
container: *root.container = undefined,
metriczServer: *root.metriczServer = undefined,
httpServer: *root.httpServer = undefined,
migrations: *root.migration = undefined,
cronz: ?*root.cronz = null,
startupHook: ?*const fn (*root.Context) anyerror!void = null,

var hServer: *root.httpServer = undefined;
var AppInstance: *Self = undefined;

pub fn new(allocator: std.mem.Allocator) !*App {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    const log = try root.logger.create(allocator);

    const config = try root.config.create(.{
        .allocator = allocator,
        .log = log,
    });

    // reset log level
    log.logLevel = app.getLogLevel(config.getOrDefault(
        "LOG_LEVEL",
        "info",
    ));

    const container = try root.container.create(.{
        .allocator = allocator,
        .log = log,
        .config = config,
    });

    const migrations = try migration.create(container);

    app.* = .{
        .log = log,
        .config = config,
        .container = container,
        .migrations = migrations,
    };

    // register metrics server
    app.metriczServer = try root.metriczServer.create(allocator, container);

    // register http server
    app.httpServer = try root.httpServer.create(allocator, container);
    hServer = app.httpServer;

    // register auth provider refresher job
    try app.addOAuthKeyRefresher();

    try app.printPid();

    AppInstance = app;

    return app;
}

fn getLogLevel(_: *Self, level: []const u8) u8 {
    if (std.mem.eql(u8, level, "debug")) {
        return 0;
    } else if (std.mem.eql(u8, level, "info")) {
        return 1;
    } else if (std.mem.eql(u8, level, "warn")) {
        return 2;
    } else if (std.mem.eql(u8, level, "error")) {
        return 3;
    } else if (std.mem.eql(u8, level, "fatal")) {
        return 4;
    } else if (std.mem.eql(u8, level, "none")) {
        return 99;
    }

    return 1;
}

pub fn onStatup(self: *Self, hook: fn (*root.Context) anyerror!void) void {
    self.startupHook = &hook;
}

fn runStartupHooks(self: *Self) !void {
    if (self.startupHook == null) {
        return;
    }

    const _req: *httpz.Request = undefined;
    const _res: *httpz.Response = undefined;
    var context = try Context.init(self.container.allocator, self.container, _req, _res);

    if (self.startupHook) |hook| {
        hook(&context) catch |err| {
            const appName = self.config.getOrDefault("APP_NAME", "NA");
            var buffer: []u8 = undefined;
            buffer = try context.allocator.alloc(u8, 100);
            buffer = try std.fmt.bufPrint(buffer, "{s} startup hook encountered error!", .{appName});
            context.info(buffer);

            context.any(err);
        };
    }
}

fn printPid(self: *Self) !void {
    const appName = self.config.getOrDefault("APP_NAME", "NA");
    var buffer: []u8 = undefined;
    buffer = try self.container.allocator.alloc(u8, 100);
    buffer = try std.fmt.bufPrint(buffer, "{s} app pid {d}", .{ appName, std.c.getpid() });
    self.log.info(buffer);
}

pub fn run(self: *Self) !void {
    // run startup hooks
    try self.runStartupHooks();

    // register live and health check routes
    self.httpServer.router.get(constants.LIVE_PATH, live, .{});
    self.httpServer.router.get(constants.HEALTH_PATH, health, .{});

    self.httpServer.router.get(constants.OPEN_API_PATH, openAPIHandler, .{});
    self.httpServer.router.get(constants.SWAGGER_PATH, swaggerHandler, .{});
    self.httpServer.router.get("/.well-known/*", swaggerHandler, .{});

    self.httpServer.router.get("/favicon.ico", favIcon, .{});

    // register static routes
    self.httpServer.router.get("/*", staticDirectory, .{});
    const buffer = try utils.toString(
        self.container.allocator,
        "registered static files from directory {s}",
        constants.STATIC_DIR,
    );
    self.log.info(buffer);

    // add open api spec if available

    // start pubsub
    try self.startPubSubSubscriptions();

    // inject graceful shutdown handler for both servers
    try self.startShutdownHandler();

    // try self.startMetricsServer();
    try self.startHttpServer();
}

fn startPubSubSubscriptions(self: Self) !void {
    if (self.container.pubsub) |pubsub| {
        self.container.log.info("starting mqtt subscriptions");
        try pubsub.startSubscription();
    }

    if (self.container.Kakfa) |k| {
        if (k.kafkaMode != root.rdkafka.RD_KAFKA_CONSUMER) {
            return;
        }
        self.container.log.info("starting kafka subscriptions");
        try k.startSubscription();
    }
}

fn startShutdownHandler(_: Self) !void {
    // interrupt signal
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    // terminate signal
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
}

fn shutdown(_: c_int) callconv(.c) void {
    if (AppInstance.cronz) |cronz| {
        cronz.destroy();
        AppInstance.log.info("cleaning running cronz");
    }

    std.Thread.sleep(1_000_000_000);
    hServer.shutdown();
}

fn startMetricsServer(self: Self) !void {
    self.log.debug("metrics server is initialized");
    const thread = try self.metriczServer.Run();
    thread.join();
    self.log.debug("metrics server started");
}

fn startHttpServer(self: Self) !void {
    var buffer: []u8 = try self.container.allocator.alloc(u8, 100);
    buffer = try std.fmt.bufPrint(buffer, "Starting server on port: {d}", .{self.httpServer.port});
    self.container.log.info(buffer);

    const thread = self.httpServer.run() catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Server starting failed: {any}. check configs.", .{error.AddressInUse});
        self.container.log.any(err);
        return;
    };
    thread.join();
}

fn favIcon(ctx: *Context) !void {
    var f = std.fs.cwd().openFile(constants.FAVICON_FILE_PATH, .{}) catch |err| switch (err) {
        else => {
            var buffer: []u8 = try ctx.allocator.alloc(u8, 100);
            buffer = try std.fmt.bufPrint(buffer, "favorite icon not found, using default", .{});
            ctx.info(buffer);

            ctx.response.setStatus(.ok);
            ctx.response.content_type = .ICO;
            ctx.response.body = favoriteIcon;

            return;
        },
    };
    defer f.close();

    // Read the file into a buffer.
    const stat = f.stat() catch |err| {
        var buffer: []u8 = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "favorite icon not found, using default {s}", .{
            @errorName(err),
        });
        ctx.info(buffer);

        ctx.response.setStatus(.ok);
        ctx.response.content_type = .ICO;
        ctx.response.body = favoriteIcon;

        return;
    };

    const buffer = f.readToEndAlloc(ctx.allocator, stat.size) catch |err| {
        var buffer: []u8 = try ctx.allocator.alloc(u8, 100);
        buffer = try std.fmt.bufPrint(buffer, "favorite icon not found, using default {s}", .{
            @errorName(err),
        });
        ctx.info(buffer);

        ctx.response.setStatus(.ok);
        ctx.response.content_type = .ICO;
        ctx.response.body = favoriteIcon;

        return;
    };

    ctx.response.setStatus(.ok);
    ctx.response.content_type = .ICO;
    ctx.response.body = buffer;
}

fn readFile(ctx: *Context, path: []const u8) ![]const u8 {
    var filePath: []u8 = undefined;
    filePath = try ctx.allocator.alloc(u8, 100);
    filePath = try std.fs.cwd().realpath(path, filePath);

    var f = try std.fs.cwd().openFile(filePath, .{});
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();

    const buffer = f.readToEndAlloc(ctx.allocator, stat.size);
    return buffer;
}

fn openAPIHandler(ctx: *Context) !void {
    var urlPath: []u8 = undefined;
    urlPath = try ctx.allocator.alloc(u8, 100);
    urlPath = try std.fmt.bufPrint(urlPath, "{s}/openapi.json", .{constants.STATIC_DIR});

    const buffer = try readFile(ctx, urlPath);

    ctx.response.setStatus(.ok);
    ctx.response.body = buffer;
}

fn swaggerHandler(ctx: *Context) !void {
    const path: []const u8 = ctx.request.url.path;
    if (std.mem.eql(u8, path, constants.indexCss)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .CSS;
        ctx.response.body = indexCss;
    } else if (std.mem.eql(u8, path, constants.indexHtml)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .HTML;
        ctx.response.body = indexHtml;
    } else if (std.mem.eql(u8, path, constants.oauthRedirect)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .HTML;
        ctx.response.body = oauthRedirect;
    } else if (std.mem.eql(u8, path, constants.oauthRedirectJs)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .JS;
        ctx.response.body = oauthRedirectJs;
    } else if (std.mem.eql(u8, path, constants.swaggerInitializerJs)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .JS;
        ctx.response.body = swaggerInitializerJs;
    } else if (std.mem.eql(u8, path, constants.swaggerUIBundle)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .JS;
        ctx.response.body = swaggerUIBundle;
    } else if (std.mem.eql(u8, path, constants.swaggerUIBundlerPreset)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .JS;
        ctx.response.body = swaggerUIBundlerPreset;
    } else if (std.mem.eql(u8, path, constants.swaggerUICss)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .CSS;
        ctx.response.body = swaggerUICss;
    } else if (std.mem.eql(u8, path, constants.swaggerUIJs)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .JS;
        ctx.response.body = swaggerUIJs;
    } else if (std.mem.eql(u8, path, constants.swagger)) {
        ctx.response.setStatus(.ok);
        ctx.response.content_type = .HTML;
        ctx.response.body = indexHtml;
    }
}

fn swaggerDirectory(ctx: *Context) !void {
    var urlPath: []u8 = undefined;
    urlPath = try ctx.allocator.alloc(u8, 100);
    urlPath = try std.fmt.bufPrint(urlPath, "{s}/{s}", .{ constants.STATIC_DIR, ctx.request.url.path });

    const buffer = try readFile(ctx, urlPath);

    ctx.response.setStatus(.ok);
    ctx.response.body = buffer;
}

fn staticDirectory(ctx: *Context) !void {
    var urlPath: []u8 = undefined;
    urlPath = try ctx.allocator.alloc(u8, 100);
    urlPath = try std.fmt.bufPrint(urlPath, "{s}/{s}", .{ constants.STATIC_DIR, ctx.request.url.path });

    const buffer = try readFile(ctx, urlPath);

    ctx.response.setStatus(.ok);
    ctx.response.body = buffer;
}

pub fn health(ctx: *Context) !void {
    ctx.response.setStatus(.ok);

    // recursively check all resources
    // ctx.container.sql.health();

    const services = .{
        .name = ctx.container.appName,
        .version = ctx.container.appVersion,
        .status = constants.STATUS_UP,
    };

    try ctx.response.json(services, .{});
}

pub fn live(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    try ctx.response.json(.{ .status = constants.STATUS_UP }, .{});
}

pub fn addWebsocket(self: Self, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.get("/ws", handler, .{});
}

pub fn get(self: Self, path: []const u8, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.get(path, handler, .{});
}

pub fn post(self: Self, path: []const u8, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.post(path, handler, .{});
}

pub fn put(self: Self, path: []const u8, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.put(path, handler, .{});
}

pub fn patch(self: Self, path: []const u8, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.patch(path, handler, .{});
}

pub fn delete(self: Self, path: []const u8, handler: *const fn (*root.Context) anyerror!void) !void {
    self.httpServer.router.delete(path, handler, .{});
}

pub fn addMigration(self: *Self, key: []const u8, m: *const migrate) !void {
    // add to migration map
    try self.migrations.map.put(key, m);

    // add migration key
    const epoch = try std.fmt.parseInt(i64, key, 10);
    try self.migrations.keys.append(epoch);
}

pub fn runMigrations(self: *Self) !void {
    self.migrations.run() catch |err| switch (err) {
        error.InvalidCharacter => {
            std.debug.print("{any}", .{err});
        },
        else => {
            self.container.log.err("migration execution error");
            self.container.log.any(err);
        },
    };
}

pub fn addHttpService(self: *Self, name: []const u8, address: []const u8) !void {
    const service = try zeroClient.create(self.container, name, address);
    try self.container.registerZeroClient(service);
}

pub fn addCronJob(self: *Self, schedule: []const u8, name: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.cronz == null) {
        self.cronz = try Cronz.create(self.container);
    }

    try self.cronz.?.addCron(schedule, name, hook);
}

pub fn addSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.pubsub == null) {
        self.container.log.err("pubsub is disabled, topic subscription is not available.");
        return;
    }
    try self.container.pubsub.?.addSubscriber(topic, hook);
}

pub fn addKafkaSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.Kakfa == null) {
        self.container.log.err("pubsub is disabled, topic subscription is not available.");
        return;
    }

    try self.container.Kakfa.?.addSubscriber(topic, hook);
}

pub fn addOAuthKeyRefresher(self: *Self) anyerror!void {
    if (self.httpServer.provider == null) {
        return;
    }

    if (self.httpServer.provider) |provider| {
        switch (provider.mode) {
            .OAuth => {
                var schedule: []u8 = undefined;
                if (provider.refreshInterval < 60) {
                    schedule = try self.container.allocator.alloc(u8, 100);
                    schedule = try std.fmt.bufPrint(schedule, "*/{d} * * * * *", .{provider.refreshInterval});
                } else {
                    const occurance: u16 = @as(u16, @intCast(provider.refreshInterval)) / 60;
                    schedule = try self.container.allocator.alloc(u8, 100);
                    schedule = try std.fmt.bufPrint(schedule, "0 {d} * * * *", .{occurance});
                }
                self.container.log.info(schedule);

                //register http client
                try self.addHttpService("zero-jwks-service", provider.pathUrl);

                //register job to refresh
                try self.addCronJob(schedule, "zero-jwks-refresher", AuthProvider.refreshKeys);
            },
            else => {
                // do nothing
            },
        }
    }
}
