const std = @import("std");
const root = @import("zero.zig");
const EnvMap = std.process.Environ.Map;

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
const AuthProvider = root.AuthProvider;
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

envMap: *EnvMap = undefined,
log: *root.logger = undefined,
config: *root.config = undefined,
container: *root.container = undefined,
metriczServer: *root.metriczServer = undefined,
httpServer: *root.httpServer = undefined,
metriczThread: ?std.Thread = null,
migrations: *root.migration = undefined,
cronz: ?*root.cronz = null,
    startupHook: ?*const fn (*root.Context) anyerror!void = null,
    reload_thread: ?std.Thread = null,

    /// Runtime allocator (request/response + datasource clients). Distinct from the
    /// bootstrap arena below.
    allocator: std.mem.Allocator = undefined,
    /// Tier A: a single pre-allocated fixed region holding framework-internal
    /// bootstrap allocations (container wiring, auth keys, startup log buffers,
    /// cron scheduler). Sized by `ZERO_FRAMEWORK_MEM_SIZE` (MiB). Never tied to a
    /// request lifecycle; fail-fast if exhausted at startup.
    bootstrap_fba: std.heap.FixedBufferAllocator = undefined,
    bootstrap_allocator: std.mem.Allocator = undefined,
    bootstrap_backing: []u8 = undefined,

var hServer: ?*root.httpServer = undefined;
var AppInstance: *Self = undefined;

pub fn new(allocator: std.mem.Allocator, em: *EnvMap) !*App {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    const log = try root.logger.create(allocator);

    // structured logging: LOG_FORMAT=json emits one JSON object per log line.
    // Set this before config creation so early logs (e.g. "Loaded config from file")
    // are also emitted as JSON.
    if (em.get("LOG_FORMAT") != null and std.mem.eql(u8, em.get("LOG_FORMAT").?, "json")) {
        root.logger.setJsonFormat(true);
    }

    // log timestamps use the system local zone by default; ZERO_LOG_TIMEZONE can
    // force a specific zone ("utc" | "local" | IANA name). Set this before config
    // creation so even the first log line ("Loaded config from file") honors it.
    root.utils.setLogTimezone(em.get("ZERO_LOG_TIMEZONE") orelse "local");

    const config = try root.config.create(.{
        .allocator = allocator,
        .log = log,
        .environments = em,
    });

    // reset log level
    log.logLevel = app.getLogLevel(config.getOrDefault(
        "LOG_LEVEL",
        "info",
    ));

    // --- Tier A: pre-allocated bootstrap arena ---------------------------------
    // One fixed region, sized by ZERO_FRAMEWORK_MEM_SIZE (MiB, default 8), holding
    // all framework-internal bootstrap allocations. It is never tied to a request
    // lifecycle. If it is exhausted during bootstrap we fail fast with a clear
    // error rather than grow unpredictably (RSS stays bounded).
    const framework_mem_mib: usize = blk: {
        const v = config.getAsInt("ZERO_FRAMEWORK_MEM_SIZE") catch 0;
        break :blk if (v == 0) @as(usize, 8) else @as(usize, v);
    };
    const backing = try allocator.alloc(u8, framework_mem_mib * 1024 * 1024);
    errdefer allocator.free(backing);
    // The allocator state must live in the heap-resident App struct (field below),
    // so its vtable/ptr survive after `new` returns. Computed before the struct
    // literal assignment so `bootstrap_allocator` can reference it.
    app.bootstrap_fba = std.heap.FixedBufferAllocator.init(backing);
    const bootstrap_alloc = app.bootstrap_fba.allocator();

    const container = root.container.create(.{
        .allocator = allocator,
        .log = log,
        .config = config,
        .bootstrap_allocator = bootstrap_alloc,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.BootstrapArenaExhausted,
        else => return e,
    };

    const migrations = try migration.create(container);

    // Single struct-literal assignment: this applies the declared defaults (null)
    // to every field not listed, so e.g. `startupHook` is properly null rather
    // than retaining uninitialized memory. The Tier A bootstrap fields are included
    // explicitly so they are not reset to `undefined`.
    app.* = .{
        .log = log,
        .config = config,
        .container = container,
        .migrations = migrations,
        .allocator = allocator,
        .bootstrap_backing = backing,
        .bootstrap_fba = app.bootstrap_fba,
        .bootstrap_allocator = bootstrap_alloc,
    };

    // register metrics server
    app.metriczServer = try root.metriczServer.create(allocator, container);

    // register http server
    app.httpServer = root.httpServer.create(allocator, container) catch |e| switch (e) {
        error.OutOfMemory => return error.BootstrapArenaExhausted,
        else => return e,
    };
    hServer = app.httpServer;

    // register auth provider refresher job
    try app.addOAuthKeyRefresher();

    try app.printPid();

    AppInstance = app;

    // Fail-fast on missing required config keys. Opt-in via REQUIRED_CONFIG_KEYS
    // (comma-separated). Empty by default so existing apps/tests are unaffected.
    const reqKeys = app.config.getOrDefault("REQUIRED_CONFIG_KEYS", "");
    if (reqKeys.len > 0) {
        var it = std.mem.splitScalar(u8, reqKeys, ',');
        while (it.next()) |k| {
            const trimmed = std.mem.trim(u8, k, " ");
            if (trimmed.len == 0) continue;
            if (app.config.get(trimmed).len == 0) {
                const msg = try utils.combine(app.container.allocator, "required config key missing or empty: {s}", .{trimmed});
                app.log.err(msg);
                return error.MissingRequiredConfig;
            }
        }
    }

    return app;
}

/// Frees the Tier A bootstrap arena backing. Call only after all framework
/// subsystems have been torn down (end of `run`), since the container's maps and
/// other bootstrap singletons live inside that region.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.bootstrap_backing);
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

/// Parses a log-level name into its numeric value. Returns `null` for unknown
/// names. Mirrors `getLogLevel` but errors instead of defaulting to `info`.
pub fn parseLogLevel(level: []const u8) ?u8 {
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
    return null;
}

/// Maps a numeric log level back to its name.
pub fn logLevelName(level: u8) []const u8 {
    return switch (level) {
        0 => "debug",
        1 => "info",
        2 => "warn",
        3 => "error",
        4 => "fatal",
        else => "none",
    };
}

/// Hot-reloads the log level at runtime without a restart. Returns `false` if
/// `level` is not a recognized name (the current level is left unchanged).
pub fn setLogLevel(self: *Self, level: []const u8) bool {
    const v = parseLogLevel(level) orelse return false;
    self.log.logLevel = v;
    return true;
}

/// Service name used for the outbound HTTP client registered from `REMOTE_LOG_URL`.
const remoteLogLevelService = "zero-remote-log";

/// JSON response shape expected from the remote log-level endpoint.
const remoteLogLevelResponse = struct { level: []const u8 };

/// Cron hook that pulls the current log level from the configured remote endpoint
/// and applies it internally via `parseLogLevel`. Registered by `startRemoteLogLevel`
/// when `REMOTE_LOG_URL` is set.
fn remoteLogLevelSync(ctx: *root.Context) !void {
    const client = ctx.getService(remoteLogLevelService) orelse return;
    const resp = try client.get(ctx, remoteLogLevelResponse, "", null, null);
    if (resp) |r| {
        if (parseLogLevel(r.level)) |v| {
            ctx.container.log.logLevel = v;
        }
    }
}

/// When `REMOTE_LOG_URL` is configured, registers an outbound HTTP client for it and
/// a cron job that fetches the remote level every `REMOTE_LOG_FETCH_INTERVAL` seconds
/// (default 15) and adjusts the in-process log level. No-op when the URL is unset, so
/// the feature is opt-in via config and never exposes an endpoint on this service.
pub fn startRemoteLogLevel(self: *Self) !void {
    const url = self.config.getOrDefault("REMOTE_LOG_URL", "");
    if (url.len == 0) return;

    const interval = std.fmt.parseInt(u64, self.config.getOrDefault("REMOTE_LOG_FETCH_INTERVAL", "15"), 10) catch 15;
    const step = if (interval == 0) @as(u64, 15) else interval;

    try self.addHttpService(remoteLogLevelService, url, .{});

    const schedule = try std.fmt.allocPrint(self.config.allocator, "*/{d} * * * * *", .{step});
    defer self.config.allocator.free(schedule);
    try self.addCronJob(schedule, "remote-log-level-sync", remoteLogLevelSync);
}

test "parseLogLevel / logLevelName round-trip" {
    try std.testing.expectEqual(@as(?u8, 0), parseLogLevel("debug"));
    try std.testing.expectEqual(@as(?u8, 1), parseLogLevel("info"));
    try std.testing.expectEqual(@as(?u8, 2), parseLogLevel("warn"));
    try std.testing.expectEqual(@as(?u8, 3), parseLogLevel("error"));
    try std.testing.expectEqual(@as(?u8, 4), parseLogLevel("fatal"));
    try std.testing.expectEqual(@as(?u8, 99), parseLogLevel("none"));
    try std.testing.expectEqual(@as(?u8, null), parseLogLevel("verbose"));
    try std.testing.expectEqual(@as(?u8, null), parseLogLevel(""));

    try std.testing.expectEqualStrings("debug", logLevelName(0));
    try std.testing.expectEqualStrings("info", logLevelName(1));
    try std.testing.expectEqualStrings("warn", logLevelName(2));
    try std.testing.expectEqualStrings("error", logLevelName(3));
    try std.testing.expectEqualStrings("fatal", logLevelName(4));
    try std.testing.expectEqualStrings("none", logLevelName(99));
    try std.testing.expectEqualStrings("none", logLevelName(7));
}

test "app: health aggregates custom checks and reports 503 on failure" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var c: root.container = .{ .allocator = testing.arena };
    c.appName = "demo";
    c.appVersion = "9.9";
    c.healthChecks = std.array_list.Managed(root.container.HealthCheck).init(testing.arena);

    const ok: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {}
    }.f;
    const bad: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {
            return error.Sick;
        }
    }.f;

    try c.healthChecks.append(.{ .name = "cache", .check = ok });
    try c.healthChecks.append(.{ .name = "billing", .check = bad });

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.container = &c;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try health(&ctx);
    const pr = try testing.parseResponse();
    try std.testing.expectEqual(@as(u16, 503), pr.status);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "DOWN") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "billing") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "cache") != null);
}

test "app: health reports 200 UP when all custom checks pass" {
    const t = httpz.testing;
    var testing = t.init(.{});
    defer testing.deinit();

    var c: root.container = .{ .allocator = testing.arena };
    c.appName = "demo";
    c.appVersion = "9.9";
    c.healthChecks = std.array_list.Managed(root.container.HealthCheck).init(testing.arena);

    const ok: *const fn (*root.container) anyerror!void = struct {
        fn f(_: *root.container) anyerror!void {}
    }.f;
    try c.healthChecks.append(.{ .name = "cache", .check = ok });

    var ctx: Context = undefined;
    ctx.allocator = testing.arena;
    ctx.container = &c;
    ctx.request = testing.req;
    ctx.response = testing.res;

    try health(&ctx);
    const pr = try testing.parseResponse();
    try std.testing.expectEqual(@as(u16, 200), pr.status);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "UP") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr.body, "cache") != null);
}

pub fn onStartup(self: *Self, hook: fn (*root.Context) anyerror!void) void {
    self.startupHook = &hook;
}

/// Returns the metrics registry so apps can register custom counters, gauges,
/// and histograms that are exposed on the `/metrics` endpoint.
pub fn Metric(self: *Self) *root.metricz {
    return self.container.metricz;
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

fn prepareDefaultRoutes(self: *Self) !void {
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
}

pub fn run(self: *Self) !void {
    // run startup hooks
    try self.runStartupHooks();

    // add default routes
    try self.prepareDefaultRoutes();

    // start pubsub
    try self.startPubSubSubscriptions();

    // inject graceful shutdown handler for both servers
    try self.startShutdownHandler();

    // opt-in: pull log level from a remote endpoint on a cron schedule
    try self.startRemoteLogLevel();

    // try self.startMetricsServer();
    try self.startMetricsServer();

    try self.startHttpServer();

    // The http server has stopped (e.g. after a SIGINT/SIGTERM via the
    // shutdown handler). Tear down the rest in NORMAL execution flow — never
    // from the signal handler itself, where joining threads or freeing client
    // state (while their background threads are still running) is UB/deadlock
    // and can leave the process hanging (e.g. the NATS io_task thread).
    if (self.metriczThread) |mthread| {
        self.metriczServer.stop();
        mthread.join();
        self.metriczServer.deinit();
    }
    if (self.cronz) |cronz| {
        cronz.destroy();
    }
    if (self.container.Nats) |n| {
        n.destroy();
    }
    if (self.container.mqtt) |pb| {
        pb.destroy();
    }
    if (self.container.Kakfa) |k| {
        k.destroy();
    }

    self.container.destroy();

    // All framework subsystems are torn down; release the Tier A bootstrap arena.
    self.deinit();
}

fn startPubSubSubscriptions(self: Self) !void {
    if (self.container.mqtt) |pubsub| {
        self.container.log.info("starting mqtt subscriptions");
        try pubsub.startSubscription();
    }

    if (self.container.Kakfa) |k| {
        if (k.kafkaMode == root.rdkafka.RD_KAFKA_CONSUMER) {
            self.container.log.info("starting kafka subscriptions");
            try k.startSubscription();
        }
    }

    if (self.container.Nats) |n| {
        self.container.log.info("starting nats subscriptions");
        try n.startSubscription();
    }

    if (self.container.Redis) |r| {
        self.container.log.info("starting redis subscriptions");
        try r.startSubscription();
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

fn shutdown(_: std.c.SIG) callconv(.c) void {
    // Signal shutdown only. Joining threads / tearing down from a signal
    // handler is undefined behavior (can deadlock), so we just stop the
    // scheduler loop and stop the http server. The actual thread join for
    // cronz happens later in run() once the server thread exits.
    if (AppInstance.cronz) |cronz| {
        cronz.stop();
        AppInstance.log.info("cleaning running cronz");
    }

    if (hServer) |h| {
        h.shutdown();
    }
}

pub fn shutdownApp(_: Self) void {
    if (AppInstance.cronz) |cronz| {
        cronz.destroy();
        AppInstance.log.info("cleaning running cronz");
    }

    if (hServer) |h| {
        h.shutdown();
    }
}

fn startMetricsServer(self: *Self) !void {
    self.log.debug("metrics server is initialized");
    self.metriczThread = try self.metriczServer.Run();
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

pub fn prepareHttpServer(self: Self) !std.Thread {
    var buffer: []u8 = try self.container.allocator.alloc(u8, 100);
    buffer = try std.fmt.bufPrint(buffer, "Starting server on port: {d}", .{self.httpServer.port});
    self.container.log.info(buffer);

    // register signal handlers
    // TODO: make it clean
    // try self.startShutdownHandler();

    return self.httpServer.run() catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Server starting failed: {any}. check configs.", .{error.AddressInUse});
        self.container.log.any(err);
        return err;
    };
}

fn favIcon(ctx: *Context) !void {
    var f = std.Io.Dir.cwd().openFile(utils.io, constants.FAVICON_FILE_PATH, .{}) catch |err| switch (err) {
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
    defer f.close(utils.io);

    // Read the file into a buffer.
    const stat = f.stat(utils.io) catch |err| {
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

    const buffer = try ctx.allocator.alloc(u8, stat.size);
    _ = try f.readPositionalAll(utils.io, buffer, 0);

    ctx.response.setStatus(.ok);
    ctx.response.content_type = .ICO;
    ctx.response.body = buffer;
}

fn readFile(ctx: *Context, path: []const u8) ![]const u8 {
    var f = try std.Io.Dir.cwd().openFile(utils.io, path, .{});
    defer f.close(utils.io);

    // Read the file into a buffer.
    const stat = try f.stat(utils.io);
    const buffer = try ctx.allocator.alloc(u8, stat.size);
    _ = try f.readPositionalAll(utils.io, buffer, 0);
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
    // user-registered mounts take precedence over the embedded static dir
    if (ctx.container.staticMounts.items.len > 0) {
        if (root.container.staticResolve(ctx.container.staticMounts.items, ctx.request.url.path)) |hit| {
            var rel = hit.rel;
            if (rel.len == 0) rel = "/";
            const fname = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
            const name = if (fname.len == 0) "index.html" else fname;

            const dir = if (hit.mount.dir.len > 0 and hit.mount.dir[hit.mount.dir.len - 1] == '/')
                hit.mount.dir[0 .. hit.mount.dir.len - 1]
            else
                hit.mount.dir;
            const fp = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ dir, name });
            defer ctx.allocator.free(fp);

            const buffer = readFile(ctx, fp) catch {
                ctx.response.setStatus(.not_found);
                return;
            };
            ctx.response.setStatus(.ok);
            ctx.response.content_type = httpz.ContentType.forExtension(std.fs.path.extension(fp));
            ctx.response.body = buffer;
            return;
        }
    }

    var urlPath: []u8 = undefined;
    urlPath = try ctx.allocator.alloc(u8, 100);
    urlPath = try std.fmt.bufPrint(urlPath, "{s}/{s}", .{ constants.STATIC_DIR, ctx.request.url.path });

    const buffer = readFile(ctx, urlPath) catch {
        ctx.response.setStatus(.not_found);
        return;
    };

    ctx.response.setStatus(.ok);
    ctx.response.body = buffer;
}

pub fn health(ctx: *Context) !void {
    const up: []const u8 = constants.STATUS_UP;
    const down: []const u8 = constants.STATUS_DOWN;
    var all_up = true;

    var components = std.json.ObjectMap.empty;
    defer components.deinit(ctx.allocator);

    // Run user-registered health checks; any failure flips the overall status.
    for (ctx.container.healthChecks.items) |hc| {
        if (hc.check(ctx.container)) {
            try components.put(ctx.allocator, hc.name, std.json.Value{ .string = up });
        } else |_| {
            all_up = false;
            try components.put(ctx.allocator, hc.name, std.json.Value{ .string = down });
        }
    }

    const services = .{
        .name = ctx.container.appName,
        .version = ctx.container.appVersion,
        .status = if (all_up) up else down,
        .components = std.json.Value{ .object = components },
    };

    const http_status = if (all_up) std.http.Status.ok else std.http.Status.service_unavailable;
    const status = if (all_up) up else down;

    // Content negotiation: serve an HTML status page when the client asks for
    // `text/html`; otherwise respond with JSON (the default).
    const accept = ctx.request.header("accept") orelse "";
    if (std.ascii.indexOfIgnoreCase(accept, "text/html") != null) {
        var w: std.Io.Writer.Allocating = .init(ctx.allocator);
        try w.writer.print(
            \\<!doctype html>
            \\<html><head><meta charset="utf-8"><title>{s} Health</title></head>
            \\<body><h1>Status: {s}</h1><ul>
        , .{ ctx.container.appName, status });
        var it = components.iterator();
        while (it.next()) |kv| {
            try w.writer.print("<li>{s}: {s}</li>", .{ kv.key_ptr.*, kv.value_ptr.*.string });
        }
        try w.writer.writeAll("</ul></body></html>");
        ctx.response.setStatus(http_status);
        ctx.response.content_type = .HTML;
        ctx.response.body = w.written();
        return;
    }

    ctx.response.setStatus(http_status);
    try ctx.response.json(services, .{});
}

pub fn live(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    try ctx.response.json(.{ .status = constants.STATUS_UP }, .{});
}

/// Registers a custom health check surfaced by `GET /.well-known/health`.
/// `check` must return normally when the component is healthy and error
/// otherwise; it receives the app `container` so it can probe datasources.
pub fn addHealthCheck(self: Self, name: []const u8, check: *const fn (*root.container) anyerror!void) !void {
    try self.container.healthChecks.append(.{ .name = name, .check = check });
}

/// Registers an RBAC allow-rule: `role` may call `method` on `path`. `path`
/// may end with `*` as a prefix wildcard and `method` may be `*` to match any
/// verb. Applied by the rbac middleware after auth (requires a `role` claim
/// in the verified JWT).
pub fn rbac(self: *Self, role: []const u8, method: []const u8, path: []const u8) !void {
    if (self.container.rbac == null) {
        self.container.rbac = try self.container.allocator.create(root.rbac.RBAC);
        self.container.rbac.?.* = root.rbac.RBAC.init(self.container.allocator);
    }
    try self.container.rbac.?.add(role, method, path);
}

/// Loads RBAC rules from `RBAC_ROLE_<NAME>=METHOD:/path,METHOD:/path` env keys,
/// plus a JSON document from `RBAC_CONFIG` (either an array of
/// `{"role","method","path"}` objects or an object mapping role →
/// `["METHOD:/path", ...]`).
pub fn rbacFromEnv(self: *Self) !void {
    const prefix = "RBAC_ROLE_";
    var it = self.container.config.environments.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
        const role = entry.key_ptr.*[prefix.len..];
        var rules = std.mem.splitScalar(u8, entry.value_ptr.*, ',');
        while (rules.next()) |rule| {
            const trimmed = std.mem.trim(u8, rule, " ");
            if (trimmed.len == 0) continue;
            var mp = std.mem.splitScalar(u8, trimmed, ':');
            const m = mp.next() orelse continue;
            const p = mp.next() orelse continue;
            try self.rbac(role, std.mem.trim(u8, m, " "), std.mem.trim(u8, p, " "));
        }
    }

    const json_config = self.container.config.getOrDefault("RBAC_CONFIG", "");
    if (json_config.len > 0) {
        try self.rbacFromJson(json_config);
    }
}

/// Parses RBAC rules from a JSON string (array of `{"role","method","path"}`
/// objects, or an object mapping role → `["METHOD:/path", ...]`).
pub fn rbacFromJson(self: *Self, json_config: []const u8) !void {
    if (self.container.rbac == null) {
        self.container.rbac = try self.container.allocator.create(root.rbac.RBAC);
        self.container.rbac.?.* = root.rbac.RBAC.init(self.container.allocator);
    }
    try self.container.rbac.?.fromJson(self.container.allocator, json_config);
}

/// Reads a JSON RBAC config from `path` (see `rbacFromJson` for the schema).
pub fn rbacFromJsonFile(self: *Self, path: []const u8) !void {
    const buf = std.fs.cwd().readFileAlloc(self.container.allocator, path, 1 << 20) catch {
        return root.rbac.RbacError.InvalidRbacConfig;
    };
    defer self.container.allocator.free(buf);
    try self.rbacFromJson(buf);
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

/// Registers a GraphQL-over-HTTP endpoint at `path`.
///
/// `query_root`/`mutation_root` are resolver instances (plain Zig structs whose
/// fields are constant values or `fn(*Context, Args) !T` resolvers). They must
/// outlive the request (e.g. global `var` instances).
pub fn graphql(self: *Self, comptime path: []const u8, comptime Query: type, comptime Mutation: ?type, query_root: *const Query, mutation_root: ?*const anyopaque) !void {
    self.container.graphql_query = query_root;

    self.container.graphql_mutation = mutation_root;

    try self.post(path, makeGraphQLHandler(Query, Mutation));

    try self.get(path, makeGraphQLHandler(Query, Mutation));
}

fn makeGraphQLHandler(comptime Query: type, comptime Mutation: ?type) *const fn (*root.Context) anyerror!void {
    const Impl = struct {
        fn handle(c: *root.Context) !void {
            const q: *const Query = @ptrCast(@alignCast(c.container.graphql_query orelse return error.GraphQLNoQuery));
            const m: ?*const anyopaque = if (Mutation) |_| c.container.graphql_mutation else null;
            try c.graphql(Query, Mutation, q, m);
        }
    };

    return &Impl.handle;
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

pub fn addHttpService(self: *Self, name: []const u8, address: []const u8, opts: zeroClient.ServiceOptions) !void {
    var resolved = zeroClient.fromEnv(self.container, name);
    if (opts.auth != null) {
        resolved.auth = opts.auth;
    }

    if (opts.circuitBreaker != null) {
        resolved.circuitBreaker = opts.circuitBreaker;
    }

    const service = try zeroClient.createWithConfig(
        self.container,
        name,
        address,
        resolved,
    );

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

/// Register a named KV store backend (redis / nats_kv / memory / sqlite) and
/// expose it on the request context via `ctx.GetKVStore(name)`. The first store
/// registered (or the Redis client auto-registered on connect) becomes the
/// default `ctx.KV`.
pub fn addKVStore(self: *Self, name: []const u8, backend: root.kvstore.Backend, opts: root.kvstore.Options) !void {
    const store = try root.kvstore.build(self.container, backend, opts);
    try self.container.kvStores.put(name, store);
    if (self.container.defaultKV == null) self.container.defaultKV = store;
}

pub fn addFileStore(self: *Self, name: []const u8, backend: root.filestore.Backend, opts: root.filestore.Options) !void {
    const store = try root.filestore.build(self.container, backend, opts);
    try self.container.fileStores.put(name, store);
    if (self.container.defaultFileStore == null) self.container.defaultFileStore = store;
}

/// Register the time-series datasource backend (influxdb). Exposed on the request
/// context as `ctx.Timeseries`.
pub fn addTimeseries(self: *Self, backend: root.timeseriesInterface.Backend, opts: root.timeseriesInterface.Options) !void {
    self.container.Timeseries = try root.Timeseries.build(self.container, backend, opts);
}

/// Register the search datasource backend (solr). Exposed on the request context
/// as `ctx.Search`.
pub fn addSearch(self: *Self, backend: root.searchInterface.Backend, opts: root.searchInterface.Options) !void {
    self.container.Search = try root.Search.build(self.container, backend, opts);
}

/// Register the NoSQL datasource backend (cassandra). Exposed on the request
/// context as `ctx.NoSQL`.
pub fn addNoSQL(self: *Self, backend: root.nosqlInterface.Backend, opts: root.nosqlInterface.Options) !void {
    self.container.NoSQL = try root.NoSQL.build(self.container, backend, opts);
}

/// Register the in-process OLAP SQL engine (DuckDB). Exposed on the request
/// context as `ctx.SQL` (reusing the relational `Datasource` interface). When
/// `path` is empty an in-memory database is used.
pub fn addDuckDB(self: *Self, path: []const u8) !void {
    const db = try root.DuckDB.create(self.container.allocator, path);
    self.container.DuckDB = db;
    self.container.datasource = root.Datasource.init(
        db,
        .duckdb,
        if (self.container.config.getAsBool("SQL_CIRCUIT_BREAKER_ENABLE"))
            root.circuit_breaker.CircuitBreaker.init(.{})
        else
            null,
    );

    const msg = try std.fmt.allocPrint(
        self.container.bootstrap,
        "connected to duckdb at '{s}'",
        .{if (path.len == 0) ":memory:" else path},
    );
    defer self.container.bootstrap.free(msg);
    self.container.log.info(msg);
}

/// Serves files from an on-disk directory `dir` under the URL `prefix`
/// (must start with `/`). Files are resolved with a `/` boundary, so a mount
/// at `/assets` serves `/assets/logo.png` from `<dir>/logo.png`, and the mount
/// root serves `index.html`. Resolved through the `/*` static catch-all, so
/// explicit routes still win.
pub fn addStaticFiles(self: *Self, prefix: []const u8, dir: []const u8) !void {
    if (prefix.len == 0 or prefix[0] != '/') {
        self.container.log.err("static mount prefix must start with '/'");
        return error.InvalidStaticPrefix;
    }
    try self.container.staticMounts.append(.{ .prefix = prefix, .dir = dir });
    const msg = try utils.toString(self.container.allocator, "registered static mount {s} -> {s}", .{ prefix, dir });
    self.container.log.info(msg);
}

/// Registers list/get/create/update/delete REST handlers for struct `T`
/// (see `zero.autocrud`). Mirrors GoFr's `AddRESTHandlers`.
pub fn addRestHandlers(self: *Self, comptime T: type, comptime opts: root.AutoCrudOptions) !void {
    return root.addRestHandlers(self, T, opts);
}

pub fn addKafkaSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.Kakfa == null) {
        self.container.log.err("pubsub is disabled, topic subscription is not available.");
        return;
    }

    try self.container.Kakfa.?.addSubscriber(topic, hook);
}

pub fn addNatsSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.Nats == null) {
        self.container.log.err("pubsub is disabled, topic subscription is not available.");
        return;
    }

    try self.container.Nats.?.addSubscriber(topic, hook);
}

/// Subscribe through the unified PubSub interface (backend-agnostic).
pub fn addPubSubSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.pubSub == null) {
        self.container.log.err("pubsub is disabled, topic subscription is not available.");
        return;
    }

    try self.container.pubSub.?.addSubscriber(topic, hook);
}

/// Subscribe to a Redis Pub/Sub channel (`PUBSUB_BACKEND=REDIS`).
pub fn addRedisSubscription(self: *Self, topic: []const u8, hook: fn (*root.Context) anyerror!void) !void {
    if (self.container.Redis == null) {
        self.container.log.err("redis pubsub is disabled, topic subscription is not available.");
        return;
    }

    try self.container.Redis.?.addSubscriber(topic, hook);
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
                try self.addHttpService("zero-jwks-service", provider.pathUrl, zeroClient.ServiceOptions{});

                //register job to refresh
                try self.addCronJob(schedule, "zero-jwks-refresher", AuthProvider.refreshKeys);
            },
            else => {
                // do nothing
            },
        }
    }
}
