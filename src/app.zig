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
const otel = root.otel;

/// Signature for a CLI subcommand handler. The handler uses `ctx` to access
/// datasources (`ctx.SQL`, `ctx.Cache`, …), parsed flags (`ctx.Param`), the
/// logger (`ctx.Logger` / `ctx.info`), and prints output via `ctx.println`.
pub const CliHandler = *const fn (*root.Context) anyerror!void;

/// Optional metadata for a subcommand.
pub const SubCommandOpts = struct {
    description: []const u8 = "",
    help: []const u8 = "",
};

/// Internal registry entry for a registered subcommand.
const CliSubCommand = struct {
    name: []const u8,
    handler: CliHandler,
    description: []const u8,
    help: []const u8,
};

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
/// OpenTelemetry provider. Inert unless `OTEL_EXPERIMENTAL=true` is set in config.
otelProvider: otel.Provider = .{ .enabled = false },
config: *root.config = undefined,
container: *root.container = undefined,
metriczServer: *root.metriczServer = undefined,
httpServer: *root.httpServer = undefined,
metriczThread: ?std.Thread = null,
migrations: *root.migration = undefined,
cronz: ?*root.cronz = null,
startupHook: ?*const fn (*root.Context) anyerror!void = null,
reload_thread: ?std.Thread = null,

/// Registered CLI subcommands (populated by `SubCommand` for `newCmd` apps).
subcommands: std.StringHashMap(CliSubCommand) = undefined,

/// Runtime allocator (request/response + datasource clients). Distinct from the
/// bootstrap arena below.
allocator: std.mem.Allocator = undefined,
/// A single pre-allocated fixed region holding framework-internal
/// bootstrap allocations (container wiring, auth keys, startup log buffers,
/// cron scheduler). Sized by `ZERO_FRAMEWORK_MEM_SIZE` (MiB). Never tied to a
/// request lifecycle; fail-fast if exhausted at startup.
bootstrap_fba: std.heap.FixedBufferAllocator = undefined,
bootstrap_allocator: std.mem.Allocator = undefined,
bootstrap_backing: []u8 = undefined,

var hServer: ?*root.httpServer = undefined;
var AppInstance: *Self = undefined;

/// Shared setup for both HTTP (`new`) and CLI (`newCmd`) applications: config,
/// logging, the bootstrap arena, container/datasources, migrations, and
/// fail-fast config checks. Does NOT create the HTTP or metrics servers.
fn initBase(allocator: std.mem.Allocator, io: std.Io, em: *EnvMap) !*App {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    // Seed the thin `utils.io` global from the injected reactor so stateless
    // helpers (nowMonotonic, timestampz, …) that have no *container in scope
    // can reach it. Subsystems that hold a *container use `container.io`.
    utils.setIo(io);

    const log = try root.logger.create(allocator);

    // log timestamps use the system local zone by default; ZERO_LOG_TIMEZONE can
    // force a specific zone ("utc" | "local" | IANA name). Set this before config
    // creation so even the first log line ("Loaded config from file") honors it.
    root.utils.setLogTimezone(em.get("ZERO_LOG_TIMEZONE") orelse "local");

    const config = try root.config.create(.{
        .allocator = allocator,
        .log = log,
        .environments = em,
    });

    configureLogFormat(em, config);

    // One fixed region, sized by ZERO_FRAMEWORK_MEM_SIZE (MiB, default 8), holding
    // all framework-internal bootstrap allocations. It is never tied to a request
    // lifecycle. If it is exhausted during bootstrap we fail fast with a clear
    // error rather than grow unpredictably.
    const framework_mem_mib: usize = blk: {
        const v = config.getAsInt("ZERO_FRAMEWORK_MEM_SIZE") catch 0;
        break :blk if (v == 0) constants.DEFAULT_FRAMEWORK_MEM_SIZE else @as(usize, v);
    };
    const backing = try allocator.alloc(u8, framework_mem_mib * 1024 * 1024);
    errdefer allocator.free(backing);

    // The allocator state must live in the heap-resident App struct (field below),
    // so its vtable/ptr survive after `new` returns. Computed before the struct
    // literal assignment so `bootstrap_allocator` can reference it.
    app.bootstrap_fba = std.heap.FixedBufferAllocator.init(backing);
    const bootstrap_alloc = app.bootstrap_fba.allocator();

    // OpenTelemetry: opt-in via otel_experimental=true. When off, the provider is
    // inert (no SDK objects, no background threads). See src/otel.zig. Accept both
    // the lowercase config key and the uppercase OTEL_EXPERIMENTAL env convention.
    const otel_enabled = blk: {
        const a = config.getOrDefault("OTEL_EXPERIMENTAL", "false");
        break :blk std.mem.eql(u8, a, "true");
    };

    // NOTE: the OTel provider deliberately uses the general `allocator`, NOT the
    // bootstrap FixedBufferAllocator. The SDK does high-churn per-request
    // allocation (span/log clones, batch queues) and the FBA never reclaims freed
    // memory, so sharing it makes the SDK exhaust and panic (OutOfMemory ->
    // `unreachable`) under load. The SDK's runtime memory is instead bounded by the
    // per-span freeClonedSpan discipline in span_processor.zig (RSS plateaus).
    app.otelProvider = try otel.Provider.init(allocator, io, config, otel_enabled);

    // reset log level
    log.logLevel = app.getLogLevel(config.getOrDefault(
        "LOG_LEVEL",
        "info",
    ));

    const container = root.container.create(.{
        .allocator = allocator,
        .log = log,
        .config = config,
        .io = io,
        .bootstrap_allocator = bootstrap_alloc,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.BootstrapArenaExhausted,
        else => return e,
    };

    // Expose the (possibly inert) OTel provider to subsystems that need it
    // (tracz middleware, Context, outbound service client).
    container.otel = &app.otelProvider;

    const migrations = try migration.create(container);

    // Single struct-literal assignment: this applies the declared defaults (null)
    // to every field not listed, so e.g. `startupHook` is properly null rather
    // than retaining uninitialized memory. The bootstrap fields are included
    // explicitly so they are not reset to `undefined`.
    app.* = .{
        .log = log,
        .config = config,
        .container = container,
        .otelProvider = app.otelProvider,
        .migrations = migrations,
        .allocator = allocator,
        .bootstrap_backing = backing,
        .bootstrap_fba = app.bootstrap_fba,
        .bootstrap_allocator = bootstrap_alloc,
    };
    app.subcommands = std.StringHashMap(CliSubCommand).init(allocator);

    // Fail-fast on missing required config keys (opt-in via REQUIRED_CONFIG_KEYS).
    try checkRequiredConfigKeys(allocator, config, log);

    try app.printPid();
    AppInstance = app;

    return app;
}

/// Apply JSON/OTEL log formatting from env (early) and from config (.env file).
fn configureLogFormat(em: *EnvMap, config: *root.config) void {
    if (em.get("LOG_FORMAT")) |fmt| {
        if (std.mem.eql(u8, fmt, "json")) root.logger.setJsonFormat(true);
    }
    if (std.mem.eql(u8, config.getOrDefault("LOG_FORMAT", ""), "json")) {
        root.logger.setJsonFormat(true);
    }
    if (std.mem.eql(u8, config.getOrDefault("OTEL_LOG_JSON", ""), "true")) {
        root.logger.setOtelJsonFormat(true);
    }
}

/// Fail-fast on missing required config keys (opt-in via REQUIRED_CONFIG_KEYS).
fn checkRequiredConfigKeys(allocator: std.mem.Allocator, config: *root.config, log: *root.logger) !void {
    const req_keys = config.getOrDefault("REQUIRED_CONFIG_KEYS", "");
    if (req_keys.len == 0) return;
    var it = std.mem.splitScalar(u8, req_keys, ',');
    while (it.next()) |k| {
        const trimmed = std.mem.trim(u8, k, " ");
        if (trimmed.len == 0) continue;
        if (config.get(trimmed).len == 0) {
            const msg = try utils.combine(allocator, "required config key missing or empty: {s}", .{trimmed});
            log.err(msg);
            return error.MissingRequiredConfig;
        }
    }
}

/// Create the full application: config, logging, container/datasources, and the
/// HTTP + metrics servers. Call `run()` to start serving.
pub fn new(allocator: std.mem.Allocator, io: std.Io, em: *EnvMap) !*App {
    const app = try initBase(allocator, io, em);

    // register metrics server
    app.metriczServer = try root.metriczServer.create(allocator, app.container);

    // register http server
    app.httpServer = root.httpServer.create(allocator, app.container) catch |e| switch (e) {
        error.OutOfMemory => return error.BootstrapArenaExhausted,
        else => return e,
    };
    hServer = app.httpServer;

    // register auth provider refresher job
    try app.addOAuthKeyRefresher();

    return app;
}

/// Create an application for command-line (non-HTTP) use. Everything is wired up
/// (config, logging, container/datasources, migrations) but no HTTP server or
/// metrics server is started. Register subcommands with `SubCommand` and invoke
/// with `runCmd`.
pub fn newCmd(allocator: std.mem.Allocator, io: std.Io, em: *EnvMap) !*App {
    return initBase(allocator, io, em);
}

/// Frees the bootstrap arena backing. Call only after all framework
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

/// Register a CLI subcommand. `name` is the token the user passes after the
/// program (e.g. `myapp migrate`). `handler` receives a `Context` whose
/// `params` map holds parsed `--flag value` / `--flag=value` pairs.
pub fn SubCommand(self: *App, name: []const u8, handler: CliHandler, opts: SubCommandOpts) !void {
    try self.subcommands.put(name, .{
        .name = name,
        .handler = handler,
        .description = opts.description,
        .help = opts.help,
    });
}

/// Run a command-line application: parse argv, dispatch to a registered
/// subcommand, and execute its handler with a pre-built CLI `Context`.
/// `args` is typically `init.minimal.args` from a `std.process.Init` main
/// parameter.
pub fn runCmd(self: *App, args: std.process.Args) !void {
    var it = std.process.Args.Iterator.init(args);

    // skip the program name (argv[0]).
    _ = it.next() orelse {
        self.printCliHelp();
        return;
    };

    const sub = it.next() orelse {
        self.printCliHelp();
        return;
    };

    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        self.printCliHelp();
        return;
    }

    const entry = self.subcommands.get(sub) orelse {
        const errout = std.Io.File.stderr();
        errout.writeStreamingAll(self.container.io, "unknown command: ") catch {};
        errout.writeStreamingAll(self.container.io, sub) catch {};
        errout.writeStreamingAll(self.container.io, "\n") catch {};
        self.printCliHelp();
        return error.UnknownCliCommand;
    };

    // run registered startup hooks (e.g. migrations) before the command body.
    if (self.startupHook) |hook| {
        var hctx = try root.Context.initCli(self.allocator, self.container);
        defer hctx.params.deinit();
        try hook(&hctx);
    }

    // build the command context and parse remaining args into params.
    var ctx = try root.Context.initCli(self.allocator, self.container);
    defer ctx.params.deinit();
    while (it.next()) |raw| {
        const arg = raw;
        if (std.mem.startsWith(u8, arg, "--")) {
            const kv = arg[2..];
            if (std.mem.indexOfScalar(u8, kv, '=')) |idx| {
                try ctx.params.put(kv[0..idx], kv[idx + 1 ..]);
            } else {
                const val = it.next() orelse "";
                try ctx.params.put(kv, val);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const key = arg[1..];
            const val = it.next() orelse "";
            try ctx.params.put(key, val);
        }
    }

    try entry.handler(&ctx);
}

/// Print the CLI usage banner and the list of registered subcommands.
pub fn printCliHelp(self: *App) void {
    const out = std.Io.File.stdout();
    const io = self.container.io;
    out.writeStreamingAll(io, "Usage:\n  ") catch {};
    out.writeStreamingAll(io, self.config.getOrDefault("APP_NAME", "zero")) catch {};
    out.writeStreamingAll(io, " <command> [flags]\n\nCommands:\n") catch {};
    var it = self.subcommands.iterator();
    if (self.subcommands.count() == 0) {
        out.writeStreamingAll(io, "  (none registered)\n") catch {};
        return;
    }
    while (it.next()) |e| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  {s:<16} {s}\n", .{ e.key_ptr.*, e.value_ptr.*.description }) catch "  (entry too long)\n";
        out.writeStreamingAll(io, line) catch {};
    }
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
/// a cron job that fetches the remote level every `REMOTE_LOG_REFRESH_INTERVAL` seconds
/// (default 30) and adjusts the in-process log level. No-op when the URL is unset, so
/// the feature is opt-in via config and never exposes an endpoint on this service.
pub fn startRemoteLogLevel(self: *Self) !void {
    const url = self.config.getOrDefault("REMOTE_LOG_URL", "");
    if (url.len == 0) return;

    const interval = std.fmt.parseInt(u64, self.config.getOrDefault("REMOTE_LOG_REFRESH_INTERVAL", ""), 10) catch constants.DEFAULT_REMOTE_LOG_REFRESH_INTERVAL_S;
    const step = if (interval == 0) constants.DEFAULT_REMOTE_LOG_REFRESH_INTERVAL_S else interval;

    try self.addHttpService(remoteLogLevelService, url, .{});

    const schedule = try std.fmt.allocPrint(self.config.allocator, "*/{d} * * * * *", .{step});
    defer self.config.allocator.free(schedule);
    try self.addCronJob(schedule, "remote-log-level-sync", remoteLogLevelSync);
}

/// Extracts a single query parameter value (e.g. `?id=uuid`) from the current
/// request. Returns the value subslice, or `null` when the parameter is absent.
/// httpz parses the query string into a key/value map, so we read it via `.get`.
fn queryParam(ctx: *root.Context, name: []const u8) ?[]const u8 {
    const qs = ctx.request.query() catch return null;
    return qs.get(name);
}

/// `GET /remote.log.service?id=<uuid>` — returns the current in-process log
/// level for the given service id as `{ "data": { "id": ..., "level": ... } }`.
fn remoteLogServiceGet(ctx: *root.Context) !void {
    const id = queryParam(ctx, "id") orelse "";
    const level = logLevelName(ctx.container.log.logLevel);
    try ctx.json(.{ .id = id, .level = level });
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
    // The startup `Context` (and its Postgres session) is heap-allocated from the
    // container allocator and is not request-scoped, so free the session here.
    defer {
        if (self.container.SQL != null) {
            const session = @as(*root.SQL, @ptrCast(@alignCast(context.SQL.ptr)));
            self.container.allocator.destroy(session);
        }
    }

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
    const msg = try std.fmt.bufPrint(buffer, "{s} app pid {d}", .{ appName, std.c.getpid() });
    self.log.info(msg);
    self.container.allocator.free(buffer);
}

fn prepareDefaultRoutes(self: *Self) !void {
    // register live and health check routes
    self.httpServer.router.get(constants.LIVE_PATH, live, .{});
    self.httpServer.router.get(constants.HEALTH_PATH, health, .{});
    self.httpServer.router.get(constants.STARTUP_PATH, startup, .{});

    // remote log service: expose the current in-process log level for a service id
    self.httpServer.router.get("/remote.log.service", remoteLogServiceGet, .{});

    self.httpServer.router.get(constants.OPEN_API_PATH, openAPIHandler, .{});
    self.httpServer.router.get(constants.SWAGGER_PATH, swaggerHandler, .{});
    self.httpServer.router.get("/.well-known/*", swaggerHandler, .{});

    self.httpServer.router.get("/favicon.ico", favIcon, .{});

    // register static routes
    self.httpServer.router.get("/*", staticDirectory, .{});
    var buf: [256]u8 = undefined;
    const buffer = try std.fmt.bufPrint(&buf, "registered static files from directory {s}", .{constants.STATIC_DIR});
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

    // HTTP server is now listening — signal the startup probe as ready.
    self.container.started.store(true, .monotonic);

    // The listen thread has joined, so the http server can now be safely torn
    // down. (It used to be deinited from the signal handler, racing the still
    // running thread and skipping this teardown path.)
    self.httpServer.http.deinit();
    self.allocator.destroy(self.httpServer);

    // The http server has stopped (e.g. after a SIGINT/SIGTERM via the
    // shutdown handler). Tear down the rest in NORMAL execution flow — never
    // from the signal handler itself, where joining threads or freeing client
    // state (while their background threads are still running) is UB/deadlock
    // and can leave the process hanging (e.g. the NATS io_task thread).
    if (self.metriczThread) |mthread| {
        self.metriczServer.stop();
        mthread.join();
        self.metriczServer.deinit();
        self.allocator.destroy(self.metriczServer);
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

    self.migrations.deinit();
    self.container.destroy();

    // Flush any in-flight OpenTelemetry spans/metrics and stop its background
    // exporters before the process exits. No-op when OTEL_EXPERIMENTAL is off.
    self.otelProvider.shutdown();

    // All framework subsystems are torn down; release the bootstrap arena.
    self.deinit();

    // Finally, free the `App` struct itself.
    self.allocator.destroy(self);
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
    const buffer: []u8 = try self.container.allocator.alloc(u8, 100);
    const msg = try std.fmt.bufPrint(buffer, "Starting server on port: {d}", .{self.httpServer.port});
    self.container.log.info(msg);
    self.container.allocator.free(buffer);

    const thread = self.httpServer.run() catch |err| {
        self.container.log.any(err);
        return;
    };
    thread.join();
}

pub fn prepareHttpServer(self: Self) !std.Thread {
    const buffer: []u8 = try self.container.allocator.alloc(u8, 100);
    const msg = try std.fmt.bufPrint(buffer, "Starting server on port: {d}", .{self.httpServer.port});
    self.container.log.info(msg);
    self.container.allocator.free(buffer);

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
    var f = std.Io.Dir.cwd().openFile(ctx.io, constants.FAVICON_FILE_PATH, .{}) catch |err| switch (err) {
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
    defer f.close(ctx.io);

    // Read the file into a buffer.
    const stat = f.stat(ctx.io) catch |err| {
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
    _ = try f.readPositionalAll(ctx.io, buffer, 0);

    ctx.response.setStatus(.ok);
    ctx.response.content_type = .ICO;
    ctx.response.body = buffer;
}

fn readFile(ctx: *Context, path: []const u8) ![]const u8 {
    var f = try std.Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer f.close(ctx.io);

    // Read the file into a buffer.
    const stat = try f.stat(ctx.io);
    const buffer = try ctx.allocator.alloc(u8, stat.size);
    _ = try f.readPositionalAll(ctx.io, buffer, 0);
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
    // Each check is bounded so a hung dependency can't block the probe forever.
    const check_timeout_ms: u32 = ctx.container.config.getAsInt("HEALTH_CHECK_TIMEOUT_MS") catch constants.DEFAULT_HEALTH_CHECK_TIMEOUT_MS;
    for (ctx.container.healthChecks.items) |*hc| {
        if (ctx.container.runHealthCheckBounded(hc, check_timeout_ms)) {
            try components.put(ctx.allocator, hc.name, std.json.Value{ .string = up });
        } else {
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

    ctx.response.setStatus(http_status);
    try ctx.response.json(services, .{});
}

pub fn live(ctx: *Context) !void {
    ctx.response.setStatus(.ok);
    try ctx.response.json(.{ .status = constants.STATUS_UP }, .{});
}

/// Startup probe: returns 200 only after `App.run()` has finished wiring and
/// the HTTP server is listening. Lets k8s use a dedicated probe with a longer
/// timeout so a slow startup (migrations, cold cache) doesn't kill the pod.
pub fn startup(ctx: *Context) !void {
    if (ctx.container.started.load(.monotonic)) {
        ctx.response.setStatus(.ok);
        try ctx.response.json(.{ .status = constants.STATUS_UP }, .{});
    } else {
        ctx.response.setStatus(.service_unavailable);
        try ctx.response.json(.{ .status = constants.STATUS_DOWN }, .{});
    }
}

/// Registers a custom health check surfaced by `GET /.well-known/health`.
/// `check` must return normally when the component is healthy and error
/// otherwise; it receives the app `container` so it can probe datasources.
pub fn addHealthCheck(self: Self, name: []const u8, check: *const fn (*root.container) anyerror!void) !void {
    try self.container.healthChecks.append(.{ .name = name, .check = check });
}

/// Loads RBAC rules from the `RBAC_CONFIG` env var, parsed as JSON in the
/// endpoint-rule format (see `rbacFromJson`). Only the JSON notation is
/// supported — there is no `RBAC_ROLE_*` env-var form.
pub fn rbacFromEnv(self: *Self) !void {
    const json_config = self.container.config.getOrDefault("RBAC_CONFIG", "");
    if (json_config.len > 0) {
        try self.rbacFromJson(json_config);
    }
}

/// Parses RBAC rules from a JSON string in the endpoint-rule format:
/// `{"permissions":[...],"endpoint":"...","methods":[...],"exempt":bool}`,
/// accepted as a single object or an array of such objects.
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
    if (self.container.fileStores.fetchRemove(name)) |old| {
        old.value.deinit(self.container.allocator);
    }
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

/// Register the Couchbase document backend over N1QL/HTTP and expose it on the
/// request context as `ctx.NoSQL`. No `libcouchbase` C library required.
pub fn addCouchbase(self: *Self, opts: root.nosqlInterface.Options) !void {
    self.container.NoSQL = try root.NoSQL.build(self.container, .couchbase, opts);
}

/// Register the in-process OLAP SQL engine (DuckDB). Exposed on the request
/// context as `ctx.SQL` (reusing the relational `Datasource` interface). When
/// `path` is empty an in-memory database is used.
/// Register the columnar OLAP SQL backend (ClickHouse) over HTTP and expose it
/// on the request context as `ctx.SQL`. No native driver / C library required.
pub fn addClickhouse(self: *Self, url: []const u8, database: []const u8, opts: struct { user: ?[]const u8 = null, password: ?[]const u8 = null }) !void {
    const db = try root.ClickHouse.create(self.container.allocator, .{
        .url = url,
        .database = database,
        .user = opts.user,
        .password = opts.password,
    });
    self.container.ClickHouse = db;
    self.container.datasource = root.Datasource.init(
        db,
        .clickhouse,
        if (self.container.config.getAsBool("SQL_CIRCUIT_BREAKER_ENABLE"))
            root.circuit_breaker.CircuitBreaker.init(.{})
        else
            null,
        self.container.metricz,
    );
}

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
        self.container.metricz,
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
/// (see `zero.autocrud`).
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

// ===================== Tests =====================

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

test "app: startup probe reports 503 before ready and 200 after" {
    const t = httpz.testing;

    var c: root.container = .{ .allocator = std.testing.allocator };
    c.appName = "demo";
    c.appVersion = "9.9";
    // `started` defaults to false; the container above did not call App.run().
    try std.testing.expectEqual(false, c.started.load(.monotonic));

    // Before ready: fresh testing context so the response buffer is clean.
    {
        var testing = t.init(.{});
        defer testing.deinit();
        var ctx: Context = undefined;
        ctx.allocator = testing.arena;
        ctx.container = &c;
        ctx.request = testing.req;
        ctx.response = testing.res;

        try startup(&ctx);
        const pr = try testing.parseResponse();
        try std.testing.expectEqual(@as(u16, 503), pr.status);
        try std.testing.expect(std.mem.indexOf(u8, pr.body, "DOWN") != null);
    }

    // Simulate App.run() having finished wiring and the server listening.
    c.started.store(true, .monotonic);
    {
        var testing = t.init(.{});
        defer testing.deinit();
        var ctx: Context = undefined;
        ctx.allocator = testing.arena;
        ctx.container = &c;
        ctx.request = testing.req;
        ctx.response = testing.res;

        try startup(&ctx);
        const pr = try testing.parseResponse();
        try std.testing.expectEqual(@as(u16, 200), pr.status);
        try std.testing.expect(std.mem.indexOf(u8, pr.body, "UP") != null);
    }
}
