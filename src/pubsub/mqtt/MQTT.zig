const std = @import("std");
const root = @import("../../zero.zig");
const MQTT = @This();
const Self = @This();

const mqConfig = root.mqConfig;
const mqMessage = root.mqMessage;
const mqSubscriber = root.mqSubscriber;

const time = std.time;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const arena: type = std.heap.ArenaAllocator;

const utils = root.utils;
const Context = root.Context;
const constants = root.constants;
const httpz = root.httpz;

const _req: *httpz.Request = undefined;
const _res: *httpz.Response = undefined;

thread: std.Thread = undefined,
container: *root.container = undefined,
rootContext: *root.Context = undefined,
subscriber: std.array_list.Managed(mqSubscriber) = undefined,
mu: std.Io.Mutex = undefined,
signal: Atomic(bool) = undefined,
    mqtt: root.mqttz.posix.Client311 = undefined,
    mqttClient: ?[]const u8 = undefined,
    isPubSubSet: bool = false,
    // Connection config retained so the consumer can reconnect after a drop.
    config: *const mqConfig = undefined,
    mqtt_initialized: bool = false,

pub fn create(container: *root.container, config: *const mqConfig) !*MQTT {
    const c = try container.allocator.create(MQTT);
    errdefer container.allocator.destroy(c);

    c.mu = .init;
    c.signal = Atomic(bool).init(true);
    c.container = container;
    c.subscriber = std.array_list.Managed(mqSubscriber).init(container.allocator);
    c.config = config;

    try c.connect();

    return c;
}

/// (Re)establish the MQTT connection: tear down any prior client, init a fresh
/// one, connect, and process the connack. Safe to call repeatedly on reconnect.
fn connect(self: *Self) !void {
    if (self.mqtt_initialized) {
        self.mqtt.deinit();
    }

    const config = self.config;
    const m = try root.mqttz.posix.Client311.init(self.container.io, .{
        .port = config.port,
        .ip = config.ip,
        .host = config.hostname,
        .allocator = self.container.allocator,
        .read_buf_size = 32_000,
        .write_buf_size = 32_000,
        .default_timeout = @as(i32, @intCast(config.connectionTimeout)),
        .default_retries = 3,
    });
    self.mqtt = m;
    self.mqtt_initialized = true;

    self.mqtt.connect(.{ .timeout = @as(i32, @intCast(config.connectionTimeout)) }, .{}) catch |err| {
        return err;
    };

    if (try self.mqtt.readPacket(.{})) |packet| switch (packet) {
        .disconnect => |d| {
            const msg = try utils.combine(self.container.allocator, "MQTT disconnected with reason: {s}", .{@tagName(d.reason_code)});
            self.container.log.info(msg);
        },
        .connack => |cack| {
            var msg = try utils.combine(self.container.allocator, "MQTT server connected", .{});
            self.container.log.info(msg);

            self.mqttClient = cack.assigned_client_identifier;

            if (cack.assigned_client_identifier) |id| {
                msg = try utils.combine(self.container.allocator, "MQTT client id {s}", .{id});
                self.container.log.info(msg);
            }
        },
        else => {
            const msg = try utils.combine(self.container.allocator, "could not connect to MQTT at '{s}:{d}'", .{ config.hostname, config.port });
            self.container.log.info(msg);
        },
    };

    self.isPubSubSet = true;
}

pub fn destroy(self: *Self) void {
    self.mqtt.disconnect(.{ .timeout = 1000 }, .{ .reason = .normal }) catch {};
    self.mqtt.deinit();

    self.signal.store(false, .release);
    self.thread.join();
}

pub fn Publish(self: *Self, topic: []const u8, payload: []const u8) !?u16 {
    return try self.mqtt.publish(.{}, .{
        .topic = topic,
        .message = payload,
    });
}

fn prepareChildAllocator(self: *Self) !*arena {
    const ca: *arena = try self.container.allocator.create(arena);
    errdefer self.container.allocator.destroy(ca);

    ca.* = arena.init(self.container.allocator);
    errdefer ca.deinit();

    return ca;
}

fn destroryChildAllocator(self: *Self, ca: *arena) void {
    const caPtr: *arena = @ptrCast(@alignCast(ca.allocator().ptr));
    caPtr.deinit();

    self.container.allocator.destroy(caPtr);
}

pub fn readPackets(self: *Self, subscriber: mqSubscriber) !void {
    while (self.signal.load(.monotonic)) {
        // (Re)connect if the previous session dropped.
        if (!self.mqtt_initialized) {
            self.connect() catch |err| {
                self.container.log.Any(self.container.allocator, err);
                std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
                continue;
            };
        }

        // (Re)subscribe this topic and consume its messages.
        const packet_identifier = try self.mqtt.subscribe(
            .{},
            .{ .topics = &.{.{ .filter = subscriber.topic, .qos = .at_most_once } },
        },

        );

        if (try self.mqtt.readPacket(.{})) |packet| switch (packet) {
            .disconnect => |d| {
                const msg = try utils.combine(self.container.allocator, "server disconnected us: {s}", .{@tagName(d.reason_code)});
                self.container.log.info(msg);
                self.mqtt_initialized = false;
                std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
                continue;
            },
            .suback => {
                const msg = try utils.combine(self.container.allocator, "received packet identifier {d}", .{packet_identifier});
                self.container.log.info(msg);
            },
            else => {},
        };

        self.consume(subscriber) catch |err| {
            self.container.log.Any(self.container.allocator, err);
            // Mark disconnected so the next iteration reconnects + resubscribes.
            self.mqtt_initialized = false;
            std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
            continue;
        };
        break;
    }
}

fn consume(self: *Self, subscriber: mqSubscriber) !void {
    while (self.signal.load(.monotonic)) {
        std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        const packet = try self.mqtt.readPacket(.{ .timeout = 1000 }) orelse {
            continue;
        };
        switch (packet) {
            .publish => |*publish| {
                const ca = self.prepareChildAllocator() catch |err| {
                    self.container.log.Any(self.container.allocator, err);
                    continue;
                };
                defer self.destroryChildAllocator(ca);

                var ctx = Context.init(
                    ca.allocator(),
                    self.container,
                    _req,
                    _res,
                ) catch |err| {
                    self.container.log.Any(self.container.allocator, err);
                    continue;
                };
                const context = &ctx;

                var message = mqMessage{
                    .payload = publish.message,
                    .topic = publish.topic,
                };

                // transform packet to client.response using std.json.parse.
                context.message = .{ .mqtt = &message };

                // Retry the handler a few times; on a poison message, dead-letter it
                // to `<topic>/dlq`.
                var attempt: u32 = 0;
                const max_attempts: u32 = 3;
                const backoff_ms: i64 = 500;
                while (attempt < max_attempts) : (attempt += 1) {
                    subscriber.exec(context) catch |err| {
                        self.container.log.Any(self.container.allocator, err);
                        if (attempt + 1 < max_attempts) {
                            std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
                            continue;
                        }
                        const dlq = std.fmt.allocPrint(self.container.allocator, "{s}/dlq", .{publish.topic}) catch break;
                        defer self.container.allocator.free(dlq);
                        self.container.metricz.dlq(.{ .topic = publish.topic, .consumer = "dlq" }) catch {};
                        if (self.Publish(dlq, publish.message)) |_| {} else |dlerr| self.container.log.Any(self.container.allocator, dlerr);
                        break;
                    };
                    break;
                }
            },
            else => {
                // Do nothing
            },
        }
    }
}

fn subscriptions(self: *Self) !void {
    // Spawn one thread per subscriber, then join them all afterwards. Joining
    // *inside* the loop would block on the first subscriber forever and never
    // start the rest, so only the first topic would ever be serviced.
    var threads = try std.ArrayList(std.Thread).initCapacity(self.container.allocator, 0);
    defer {
        for (threads.items) |t| t.join();
    }

    for (self.subscriber.items) |client| {
        // Subscribe + connect + consume all happen inside readPackets so a dropped
        // session is transparently reconnected and re-subscribed (see connect()).
        std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        const thread = Thread.spawn(.{}, Self.readPackets, .{ self, client }) catch |err| {
            self.container.log.Any(self.container.allocator, err);
            continue;
        };
        try threads.append(self.container.allocator, thread);
    }
}

pub fn startSubscription(self: *Self) !void {
    self.thread = Thread.spawn(.{}, Self.subscriptions, .{self}) catch |err| {
        self.container.log.Any(self.container.allocator, err);
        return;
    };
}

pub fn addSubscriber(self: *Self, topic: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    const s = mqSubscriber{
        .topic = topic,
        .name = topic,
        .exec = hook,
    };

    self.mu.lock(self.container.io) catch {};
    try self.subscriber.append(s);
    self.mu.unlock(self.container.io);

    const msg = utils.combine(
        self.container.allocator,
        "topic:{s} pubsub subscriber added",
        .{s.topic},
    ) catch |err| {
        self.container.log.Any(self.container.allocator, err);
        return;
    };

    self.container.log.info(msg);
}

/// Type-erased VTable conforming to `pubsubInterface.Interface.VTable`.
pub const vtable = root.pubsubInterface.Interface.VTable{
    .publish = struct {
        fn call(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
            const self: *MQTT = @ptrCast(@alignCast(ptr));
            _ = try self.Publish(subject, payload);
        }
    }.call,
    .subscribe = struct {
        fn call(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
            const self: *MQTT = @ptrCast(@alignCast(ptr));
            try self.addSubscriber(subject, hook);
        }
    }.call,
};
