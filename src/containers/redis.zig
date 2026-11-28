const std = @import("std");
const root = @import("../zero.zig");
const Container = @import("container.zig");

const Metricz = root.metricz;
const constants = root.constants;
const Context = root.Context;
const utils = root.utils;
const rediz = root.rediz;
const rdzClient = root.rediz.Client;
const rdzDatasource = root.rdz;
const zeroClient = root.client;
const MQTT = root.MQTT;
const mqConfig = root.mqConfig;
const natsConfig = root.natsConfig;
const rdkafka = root.rdkafka;
const kafka = root.kafka;
const build_options = @import("build_options");

pub fn loadRedis(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const hostname = c.config.get("REDIS_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis is disabled, as redis host is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const port = c.config.get("REDIS_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database port is empty.", .{});
        c.log.err(buffer);
        return;
    }

    const user = c.config.get("REDIS_USER");
    if (std.mem.eql(u8, user, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: user name is empty.", .{});
        c.log.err(buffer);
        return;
    }

    const password = c.config.get("REDIS_PASSWORD");
    if (std.mem.eql(u8, password, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to redis failed: database password is empty.", .{});
        c.log.err(buffer);
        return;
    }

    const dbInt = try c.config.getAsInt("REDIS_DB");
    const portInt = try c.config.getAsInt("REDIS_PORT");

    const addr = std.Io.net.IpAddress.parse(hostname, portInt) catch
        try std.Io.net.IpAddress.resolve(utils.io, hostname, portInt);

    // Startup resilience: transient Redis unavailability during orchestrated
    // bring-up (sidecar not ready, DNS, brief outage) must not hard-fail the
    // whole process. Retry with exponential backoff before giving up. (Replaces
    // the old `std.process.exit(1)` on connect failure.)
    const max_retries: usize = blk: {
        const v = c.config.getAsInt("REDIS_CONNECT_RETRIES") catch 0;
        break :blk if (v == 0) 5 else @as(usize, v);
    };
    var backoff_ms: u64 = blk: {
        const v = c.config.getAsInt("REDIS_CONNECT_BACKOFF_MS") catch 0;
        break :blk if (v == 0) 500 else @as(u64, v);
    };

    var attempt: usize = 0;
    while (attempt <= max_retries) : (attempt += 1) {
        const connection = addr.connect(utils.io, .{ .mode = .stream }) catch |err| {
            if (attempt < max_retries) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "redis connect attempt {d} failed ({any}); retrying in {d}ms", .{ attempt + 1, err, backoff_ms }) catch "redis connect attempt failed; retrying";
                c.log.warn(msg);
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            buffer = try std.fmt.bufPrint(buffer, "redis connection failed after {d} retries: {any}", .{ max_retries, err });
            c.log.err(buffer);
            return error.RedisConnectFailed;
        };

        c.rdz = try rdzDatasource.create(c.allocator);
        // Keep the connection and its reader/writer inside the heap-allocated `rdz` for
        // the app's lifetime. `rdzClient.init` borrows `&rdz.reader.interface` /
        // `&rdz.writer.interface`; stack-local copies would be freed before first use
        // and the client would write through a dangling vtable (general-protection fault).
        c.rdz.?.conn = connection;
        c.rdz.?.reader = connection.reader(utils.io, &c.rdz.?.rbuf);
        c.rdz.?.writer = connection.writer(utils.io, &c.rdz.?.wbuf);

        c.redis = rdzClient.init(utils.io, &c.rdz.?.reader.interface, &c.rdz.?.writer.interface, .{
            .user = null,
            .pass = password,
        }) catch |err| {
            buffer = try std.fmt.bufPrint(buffer, "redis client init failed: {any}", .{err});
            c.log.err(buffer);
            c.rdz.?.close();
            c.allocator.destroy(c.rdz.?);
            c.rdz = null;
            if (attempt < max_retries) {
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            return error.RedisConnectFailed;
        };

        // Verify the connection with a PING round-trip before declaring success.
        const ping = c.redis.?.sendAlloc([]u8, c.allocator, .{"ping"}) catch |err| {
            buffer = try std.fmt.bufPrint(buffer, "redis ping failed: {any}", .{err});
            c.log.err(buffer);
            c.rdz.?.close();
            c.allocator.destroy(c.rdz.?);
            c.rdz = null;
            c.redis = null;
            if (attempt < max_retries) {
                std.Io.sleep(utils.io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(backoff_ms))), .awake) catch {};
                backoff_ms *%= 2;
                continue;
            }
            return error.RedisConnectFailed;
        };
        c.allocator.free(ping);
        // Mirror the connected client into `rdz` so every Redis consumer
        // (KV, rate limiter, health probe) locks the same `rdz.mu` around the
        // one shared socket
        c.rdz.?.client = c.redis.?;
        // Capture reconnect parameters so a dead socket can be rebuilt in place.
        c.rdz.?.addr = addr;
        c.rdz.?.pass = password;
        break;
    }

    buffer = try std.fmt.bufPrint(buffer, "connected to redis at '{s}:{d}' on database {d}", .{ hostname, portInt, dbInt });
    c.log.info(buffer);

    // Auto-register a Redis dependency health probe so /.well-known/health
    // reflects cache availability without a manual check.
    try c.addHealthCheckEntry("redis", redisHealthCheck);

    // expose Redis through the unified KV store interface (default store)
    const redisStore = try root.kvstore.build(c, .redis, .{});
    try c.kvStores.put("cache", redisStore);
    if (c.defaultKV == null) {
        c.defaultKV = redisStore;
    }
}

pub fn redisHealthCheck(c: *Container) anyerror!void {
    if (c.redis) |*r| {
        // Serialize on the shared Redis socket so a concurrent KV/rate-limiter
        // command can't interleave RESP frames
        if (c.rdz) |rz| {
            rz.mu.lockUncancelable(utils.io);
            defer rz.mu.unlock(utils.io);
        }
        const pong = r.sendAlloc([]u8, c.allocator, .{"ping"}) catch {
            // The shared socket may have died in an outage. Rebuild it in place
            // once before declaring Redis unavailable — this heals KV, the rate
            // limiter, and the health probe at the same time (they all borrow the
            // same `rdz` reader/writer interfaces).
            if (c.rdz) |rz| {
                rz.reconnect() catch return error.RedisUnavailable;
                return;
            }
            return error.RedisUnavailable;
        };
        c.allocator.free(pong);
        return;
    }
    return error.RedisUnavailable;
}
