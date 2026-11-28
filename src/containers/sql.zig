const std = @import("std");
const root = @import("../zero.zig");
const Container = @import("container.zig");
const build_options = @import("build_options");

const Metricz = root.metricz;
const constants = root.constants;
const Context = root.Context;
const utils = root.utils;
const pgz = root.pgz;
const rediz = root.rediz;
const rdzClient = root.rediz.Client;
const rdzDatasource = root.rdz;
const zeroClient = root.client;
const MQTT = root.MQTT;
const mqConfig = root.mqConfig;
const natsConfig = root.natsConfig;
const rdkafka = root.rdkafka;
const kafka = root.kafka;

pub fn sqlHealthCheck(c: *Container) anyerror!void {
    if (c.SQL) |sql| {
        const conn = try sql.sql.acquire();
        sql.sql.release(conn);
        return;
    }
    if (c.SQLite) |_| {
        return;
    }
    if (c.DuckDB) |_| {
        return;
    }
    if (c.DuckGres) |dg| {
        const conn = try dg.sql.acquire();
        dg.sql.release(conn);
        return;
    }
    return error.DatasourceUnavailable;
}

pub fn clickhouseHealthCheck(c: *Container) anyerror!void {
    if (c.ClickHouse) |ch| {
        _ = try ch.runRaw(c.allocator, "SELECT 1");
        return;
    }
    return error.DatasourceUnavailable;
}

pub fn wireDatasource(c: *Container, ptr: anytype, dialect: anytype) void {
    c.datasource = root.Datasource.init(
        ptr,
        dialect,
        if (c.config.getAsBool("SQL_CIRCUIT_BREAKER_ENABLE"))
            root.circuit_breaker.CircuitBreaker.init(.{})
        else
            null,
        c.metricz,
    );
}

pub fn registerSqlHealth(c: *Container) !void {
    try c.addHealthCheckEntry("sql", sqlHealthCheck);
}

pub fn loadSQL(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const dialect = c.config.get("DB_DIALECT");
    if (std.mem.eql(u8, dialect, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "database is disabled, as dialect is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, dialect, "sqlite") == true) {
        try loadSQLite(c);
        return;
    }

    if (std.mem.eql(u8, dialect, "duckdb") == true) {
        // In-process DuckDB is wired by `loadDuckDB` via `DUCKDB_PATH`, not the
        // network Postgres path below, so skip the connection attempt here.
        return;
    }

    if (std.mem.eql(u8, dialect, "duckgres") == true) {
        try loadDuckGres(c);
        return;
    }

    if (std.mem.eql(u8, dialect, "mysql") == true) {
        try loadMySQL(c);
        return;
    }

    // Supabase is a managed Postgres instance; reuse the postgres backend but
    // read connection params from the `SUPABASE_DB_*` namespace (with sensible
    // defaults) so users don't have to also set the generic `DB_*` keys.
    const is_supabase = std.mem.eql(u8, dialect, "supabase");
    const eff_dialect = if (is_supabase) "postgres" else dialect;

    var hostname: []const u8 = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_HOST", "")
    else
        c.config.get("DB_HOST");
    const port: []const u8 = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_PORT", "5432")
    else
        c.config.get("DB_PORT");
    const user: []const u8 = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_USER", "postgres")
    else
        c.config.get("DB_USER");
    const password: []const u8 = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_PASSWORD", "")
    else
        c.config.get("DB_PASSWORD");
    const db: []const u8 = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_NAME", "postgres")
    else
        c.config.get("DB_NAME");

    if (is_supabase and hostname.len == 0) {
        const proj = c.config.getOrDefault("SUPABASE_DB_PROJECT", "");
        if (proj.len == 0) {
            buffer = try std.fmt.bufPrint(buffer, "connection to supabase failed: SUPABASE_DB_HOST or SUPABASE_DB_PROJECT is required.", .{});
            c.log.err(buffer);
            return;
        }
        hostname = try std.fmt.allocPrint(c.allocator, "db.{s}.supabase.co", .{proj});
    }

    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: host name is empty.", .{dialect});
        c.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database port is empty.", .{dialect});
        c.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: user name is empty.", .{dialect});
        c.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database password is empty.", .{dialect});
        c.log.err(buffer);
        return;
    }
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to {s} failed: database name is empty.", .{dialect});
        c.log.err(buffer);
        return;
    }

    const sslMode = if (is_supabase)
        c.config.getOrDefault("SUPABASE_DB_SSL_MODE", "require")
    else
        c.config.getOrDefault("DB_SSL_MODE", "disable");

    var config = root.SQL.dbConfig{
        .databaseName = db,
        .dialect = eff_dialect,
        .hostname = hostname,
        .port = port,
        .username = user,
        .password = password,
        .sslMode = sslMode,
    };

    c.SQL = try root.SQL.create(
        c.allocator,
        &config,
        c.log,
        c.metricz,
    );

    c.SQL.?.allocator = c.allocator;

    const dbPort: u16 = try std.fmt.parseInt(u16, port, 10);

    var tlsMode: pgz.Conn.Opts.TLS = .off;
    if (std.mem.eql(u8, sslMode, "require")) {
        tlsMode = .require;
    } else if (std.mem.eql(u8, sslMode, "verify-ca") or
        std.mem.eql(u8, sslMode, "verify-full") or
        std.mem.eql(u8, sslMode, "verify_full") or
        std.mem.eql(u8, sslMode, "verifyca") or
        std.mem.eql(u8, sslMode, "verifyfull"))
    {
        const rootCa = c.config.get("DB_TLS_ROOT_CA");
        if (std.mem.eql(u8, rootCa, "")) {
            tlsMode = .{ .verify_full = null };
        } else {
            tlsMode = .{ .verify_full = rootCa };
        }
    }

    // Pool size + connection/acquire timeout are configurable (defaults 10 / 10s).
    const pool_size: u16 = @intCast(blk: {
        const v = c.config.getAsInt("PG_POOL_SIZE") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_SIZE else @as(u32, v);
    });
    const acquire_timeout_ms: u32 = blk: {
        const v = c.config.getAsInt("PG_POOL_ACQUIRE_TIMEOUT_MS") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS else @as(u32, v);
    };
    const options: pgz.Pool.Opts = .{
        .size = pool_size,
        .connect = .{
            .host = hostname,
            .port = dbPort,
            .tls = tlsMode,
        },
        .auth = .{
            .application_name = c.config.get("APP_NAME"),
            .username = user,
            .password = password,
            .database = db,
            .timeout = acquire_timeout_ms,
        },
    };

    c.SQL.?.sql = pgz.Pool.init(utils.io, c.allocator, options) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        c.log.err(buffer);
        return err;
    };
    // reference metricz
    c.SQL.?.metricz = c.metricz;

    wireDatasource(c, c.SQL, .postgres);

    buffer = try std.fmt.bufPrint(buffer, "generating database connection string for {s}", .{dialect});
    c.log.info(buffer);

    buffer = try c.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(
        buffer,
        "connected to {s} user to {s} database at '{s}:{s}'{s}",
        .{ user, db, hostname, port, if (tlsMode != .off) " (tls)" else "" },
    );
    c.log.info(buffer);

    // Auto-register a SQL dependency health probe so /.well-known/health reflects
    // DB availability without the user adding a manual check.
    try registerSqlHealth(c);
}

pub fn loadSQLite(c: *Container) !void {
    // `create` calls this once via loadSQL (when DB_DIALECT=sqlite) and again
    // unconditionally below. Guarding avoids opening a second set of pooled
    // connections and overwriting — and leaking — the first one.
    if (c.SQLite != null) {
        return;
    }

    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const dbPath = c.config.get("SQLITE_PATH");
    if (std.mem.eql(u8, dbPath, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "sqlite is disabled, as sqlite path is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const sqlite_create = c.config.getAsBool("SQLITE_CREATE");
    const sqlite_write = c.config.getAsBool("SQLITE_WRITE");
    const threading = c.config.get("SQLITE_THREADING");

    // getAsInt returns 0 for a missing key, so treat 0 as "use the default".
    // Cap the pool so a bad config cannot open an unbounded number of handles.
    const configured_pool = c.config.getAsInt("SQLITE_POOL_SIZE") catch 0;
    const sqlite_pool_size: usize = if (configured_pool <= 0)
        4
    else if (configured_pool > 64)
        64
    else
        @intCast(configured_pool);

    const threading_mode = if (std.mem.eql(u8, threading, "multi-thread"))
        root.sqlitez.ThreadingMode.MultiThread
    else if (std.mem.eql(u8, threading, "single-thread"))
        root.sqlitez.ThreadingMode.SingleThread
    else if (std.mem.eql(u8, threading, "serialized"))
        root.sqlitez.ThreadingMode.Serialized
    else
        root.sqlitez.ThreadingMode.MultiThread;

    c.SQLite = try root.SQLite.init(
        c.allocator,
        dbPath,
        sqlite_create,
        sqlite_write,
        threading_mode,
        c.log,
        c.metricz,
        sqlite_pool_size,
    );

    wireDatasource(c, c.SQLite, .sqlite);

    buffer = try std.fmt.bufPrint(buffer, "connected to sqlite at '{s}' (pool size {d})", .{ dbPath, sqlite_pool_size });
    c.log.info(buffer);

    // Auto-register a SQL (sqlite) dependency health probe.
    try registerSqlHealth(c);
}

pub fn loadDuckDB(c: *Container) !void {
    if (comptime !build_options.duckdb) return;
    if (c.DuckDB != null) return;
    const path = c.config.get("DUCKDB_PATH");
    if (path.len == 0) return;

    const db = try root.DuckDB.create(c.allocator, path);
    c.DuckDB = db;
    wireDatasource(c, db, .duckdb);

    const msg = try std.fmt.allocPrint(
        c.bootstrap,
        "connected to duckdb at '{s}'",
        .{if (path.len == 0) ":memory:" else path},
    );
    defer c.bootstrap.free(msg);
    c.log.info(msg);

    // Auto-register a SQL (duckdb) dependency health probe.
    try registerSqlHealth(c);
}

pub fn loadDuckGres(c: *Container) !void {
    if (c.DuckGres != null) return;

    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const hostname = c.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to duckgres failed: host name is empty.", .{});
        c.log.err(buffer);
        return;
    }
    const port = c.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to duckgres failed: database port is empty.", .{});
        c.log.err(buffer);
        return;
    }
    // DuckDB PG-wire front-ends (e.g. duckgres / PostDuck) typically require no
    // password and accept any username/database, so these are optional and
    // defaulted rather than hard-failing the wiring. Only host/port are required.
    const user = if (std.mem.eql(u8, c.config.get("DB_USER"), "")) "duckdb" else c.config.get("DB_USER");
    const password = c.config.get("DB_PASSWORD");
    const db = if (std.mem.eql(u8, c.config.get("DB_NAME"), "")) "main" else c.config.get("DB_NAME");

    const portInt = try c.config.getAsInt("DB_PORT");
    const dbPort: u16 = @intCast(portInt);

    const sslMode = c.config.getOrDefault("DB_SSL_MODE", "disable");
    var tlsMode: pgz.Conn.Opts.TLS = .off;
    if (std.mem.eql(u8, sslMode, "require")) {
        tlsMode = .require;
    } else if (std.mem.eql(u8, sslMode, "verify-ca") or
        std.mem.eql(u8, sslMode, "verify-full") or
        std.mem.eql(u8, sslMode, "verifyca") or
        std.mem.eql(u8, sslMode, "verifyfull"))
    {
        const rootCa = c.config.get("DB_TLS_ROOT_CA");
        if (std.mem.eql(u8, rootCa, "")) {
            tlsMode = .{ .verify_full = null };
        } else {
            tlsMode = .{ .verify_full = rootCa };
        }
    }

    const pool_size: u16 = @intCast(blk: {
        const v = c.config.getAsInt("PG_POOL_SIZE") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_SIZE else @as(u32, v);
    });
    const acquire_timeout_ms: u32 = blk: {
        const v = c.config.getAsInt("PG_POOL_ACQUIRE_TIMEOUT_MS") catch 0;
        break :blk if (v == 0) constants.DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS else @as(u32, v);
    };
    const options: pgz.Pool.Opts = .{
        .size = pool_size,
        .connect = .{
            .host = hostname,
            .port = dbPort,
            .tls = tlsMode,
        },
        .auth = .{
            .application_name = c.config.get("APP_NAME"),
            .username = user,
            .password = password,
            .database = db,
            .timeout = acquire_timeout_ms,
        },
    };

    const dg = root.DuckGres.create(c.allocator, options, c.log, c.metricz) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to connect: {}", .{err});
        c.log.err(buffer);
        return err;
    };
    c.DuckGres = dg;
    wireDatasource(c, dg, .duckgres);

    buffer = try std.fmt.bufPrint(buffer, "connected to duckgres (wired) user to {s} database at '{s}:{s}'", .{ user, hostname, port });
    c.log.info(buffer);

    try registerSqlHealth(c);
}

pub fn loadMySQL(c: *Container) !void {
    if (c.MySQL != null) return;

    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    // MySQL reuses the shared `DB_*` SQL credentials (only one SQL dialect is
    // active per process); its TLS/pool settings use the `MYSQL_*` prefix.
    const hostname = c.config.get("DB_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: host name is empty.", .{});
        c.log.err(buffer);
        return;
    }
    const port = c.config.get("DB_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: database port is empty.", .{});
        c.log.err(buffer);
        return;
    }
    const user = c.config.get("DB_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: user name is empty.", .{});
        c.log.err(buffer);
        return;
    }
    const password = c.config.get("DB_PASSWORD");
    const db = c.config.get("DB_NAME");
    if (std.mem.eql(u8, db, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mysql failed: database name is empty.", .{});
        c.log.err(buffer);
        return;
    }

    const portInt = try c.config.getAsInt("DB_PORT");
    const dbPort: u16 = @intCast(portInt);

    const ssl_mode = parseMySqlSslMode(c.config.getOrDefault("MYSQL_SSL_MODE", "disabled"));
    const ssl_ca = if (std.mem.eql(u8, c.config.get("MYSQL_SSL_CA"), ""))
        null
    else
        c.config.get("MYSQL_SSL_CA");
    const pool_size = c.config.getAsInt("MYSQL_POOL_SIZE") catch 10;

    // The pool defers all socket connections until first use (lazy connect), so
    // this runs safely during `container.create` (before the io loop) and works
    // for hostname-based configs that need async DNS.
    const m = root.MySQL.create(c.allocator, utils.io, .{
        .host = hostname,
        .port = dbPort,
        .user = user,
        .password = password,
        .database = db,
        .ssl_mode = ssl_mode,
        .ssl_ca = ssl_ca,
        .max = @intCast(pool_size),
    }) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "Failed to create mysql pool: {}", .{err});
        c.log.err(buffer);
        return;
    };
    c.MySQL = m;
    wireDatasource(c, m, .mysql);

    buffer = try std.fmt.bufPrint(buffer, "configured mysql pool (size {d}) for user '{s}' at '{s}:{s}'", .{ pool_size, user, hostname, port });
    c.log.info(buffer);

    try c.addHealthCheckEntry("mysql", mysqlHealthCheck);
}

pub fn parseMySqlSslMode(s: []const u8) root.MySQL.SslMode {
    if (std.mem.eql(u8, s, "preferred")) return .preferred;
    if (std.mem.eql(u8, s, "required")) return .required;
    return .disabled;
}

pub fn mysqlHealthCheck(c: *Container) anyerror!void {
    if (c.MySQL) |m| {
        const conn = try m.acquireConn();
        defer m.releaseConn(conn);
        _ = conn.exec("SELECT 1", .{}) catch return error.DatasourceUnavailable;
        return;
    }
    return error.DatasourceUnavailable;
}

pub fn loadClickhouse(c: *Container) !void {
    const url = c.config.get("CLICKHOUSE_URL");
    if (std.mem.eql(u8, url, "")) {
        c.log.debug("clickhouse is disabled, as CLICKHOUSE_URL is not provided.");
        return;
    }

    const db = try root.ClickHouse.create(c.allocator, .{
        .url = url,
        .database = c.config.get("CLICKHOUSE_DB"),
        .user = if (std.mem.eql(u8, c.config.get("CLICKHOUSE_USER"), "")) null else c.config.get("CLICKHOUSE_USER"),
        .password = if (std.mem.eql(u8, c.config.get("CLICKHOUSE_PASSWORD"), "")) null else c.config.get("CLICKHOUSE_PASSWORD"),
    });
    c.ClickHouse = db;
    wireDatasource(c, db, .clickhouse);

    const msg = try std.fmt.allocPrint(c.bootstrap, "connected to clickhouse at '{s}' (db '{s}')", .{ url, c.config.get("CLICKHOUSE_DB") });
    defer c.bootstrap.free(msg);
    c.log.info(msg);

    // Auto-register a SQL (clickhouse) dependency health probe.
    try c.addHealthCheckEntry("sql", clickhouseHealthCheck);
}
