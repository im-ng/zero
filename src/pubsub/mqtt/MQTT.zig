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
mu: std.Thread.Mutex = undefined,
signal: Atomic(bool) = undefined,
mqtt: root.mqttz.posix.Client = undefined,
mqttClient: ?[]const u8 = undefined,
isPubSubSet: bool = false,

pub fn create(container: *root.container, config: *const mqConfig) !*MQTT {
    const c = try container.allocator.create(MQTT);
    errdefer container.allocator.destroy(c);

    c.mu = .{};
    c.signal = Atomic(bool).init(true);
    c.container = container;
    c.subscriber = std.array_list.Managed(mqSubscriber).init(container.allocator);

    const m = try root.mqttz.posix.Client.init(.{
        .port = config.port,
        .ip = config.ip,
        .host = config.hostname,
        .allocator = container.allocator,
        .read_buf_size = 32_000,
        .write_buf_size = 32_000,
        .default_timeout = @as(i32, @intCast(config.connectionTimeout)),
        .default_retries = 3,
    });
    c.mqtt = m;

    c.mqtt.connect(.{ .timeout = @as(i32, @intCast(config.connectionTimeout)) }, .{}) catch |err| {
        return err;
    };

    if (try c.mqtt.readPacket(.{})) |packet| switch (packet) {
        .disconnect => |d| {
            const msg = try utils.combine(container.allocator, "MQTT disconnected with reason: {s}", .{@tagName(d.reason_code)});
            container.log.info(msg);
        },
        .connack => |cack| {
            var msg = try utils.combine(container.allocator, "MQTT server connected", .{});
            container.log.info(msg);

            c.mqttClient = cack.assigned_client_identifier;

            msg = try utils.combine(container.allocator, "MQTT client id {s}", .{cack.assigned_client_identifier.?});
            container.log.info(msg);
        },
        else => {
            const msg = try utils.combine(container.allocator, "could not connect to MQTT at '{s}:{d}'", .{ config.hostname, config.port });
            container.log.info(msg);
        },
    };

    c.isPubSubSet = true;

    return c;
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
        std.Thread.sleep(std.time.ns_per_s);
        const packet = try self.mqtt.readPacket(.{ .timeout = 1000 }) orelse {
            continue;
        };
        switch (packet) {
            .publish => |*publish| {
                const ca = self.prepareChildAllocator() catch |err| {
                    self.container.log.any(err);
                    continue;
                };
                defer self.destroryChildAllocator(ca);

                var ctx = Context.init(
                    ca.allocator(),
                    self.container,
                    _req,
                    _res,
                ) catch |err| {
                    self.container.log.any(err);
                    return;
                };
                const context = &ctx;

                var message = mqMessage{
                    .payload = publish.message,
                    .topic = publish.topic,
                };

                // transform packet to client.response using std.json.parse.
                context.message = &message;

                try subscriber.exec(context);
            },
            else => {
                // self.container.log.err("unexpected packet found");
                // self.container.log.any(packet);
                // Do nothing
            },
        }
    }
}

fn subscriptions(self: *Self) !void {
    for (self.subscriber.items) |client| {
        const packet_identifier = try self.mqtt.subscribe(
            .{},
            .{ .topics = &.{.{
                .filter = client.topic,
                .qos = .at_most_once,
            }} },
        );

        // persist packet identifier
        // client.packetIdentifier = packet_identifier;

        if (try self.mqtt.readPacket(.{})) |packet| switch (packet) {
            .disconnect => |d| {
                const msg = try utils.combine(self.container.allocator, "server disconnected us: {s}", .{@tagName(d.reason_code)});
                self.container.log.info(msg);
                return;
            },
            .suback => {
                const msg = try utils.combine(self.container.allocator, "received packet identifier {d}", .{packet_identifier});
                self.container.log.info(msg);
            },
            else => {
                // do nothing
            },
        };

        std.Thread.sleep(std.time.ns_per_ms * 100);
        const thread = Thread.spawn(.{}, Self.readPackets, .{ self, client }) catch |err| {
            self.container.log.any(err);
            return;
        };
        thread.join();
    }
}

pub fn startSubscription(self: *Self) !void {
    self.thread = Thread.spawn(.{}, Self.subscriptions, .{self}) catch |err| {
        self.container.log.any(err);
        return;
    };
}

pub fn addSubscriber(self: *Self, topic: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    const s = mqSubscriber{
        .topic = topic,
        .name = topic,
        .exec = hook,
    };

    self.mu.lock();
    try self.subscriber.append(s);
    self.mu.unlock();

    const msg = utils.combine(
        self.container.allocator,
        "topic:{s} pubsub subscriber added",
        .{s.topic},
    ) catch |err| {
        self.container.log.any(err);
        return;
    };

    self.container.log.info(msg);
}
