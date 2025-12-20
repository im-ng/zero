const std = @import("std");
const root = @import("../../zero.zig");
const Kafka = @This();
const Self = @This();

const kConfig = root.kConfig;
const rdkafka = root.rdkafka;
const kafkaSubscriber = root.kafkaSubscriber;
const kafkaMessage = root.kafkaMessage;

pub const kafkaConfig = root.rdkafka.struct_rd_kafka_conf_s;
pub const kafkaClient = root.rdkafka.rd_kafka_t;
pub const kafkaTopic = root.rdkafka.struct_rd_kafka_topic_s;

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
mu: std.Thread.Mutex = undefined,
signal: Atomic(bool) = undefined,
config: ?*kafkaConfig,
topic: ?*kafkaTopic,
client: ?*kafkaClient,
subscriber: std.array_list.Managed(kafkaSubscriber) = undefined,
isPubSubSet: bool = false,
kafkaMode: c_uint = 0,
err_message: [4096]u8 = undefined,

pub fn create(
    container: *root.container,
    config: ?*kafkaConfig,
    topic: ?*kafkaTopic,
    mode: c_uint,
) !*Kafka {
    const c = try container.allocator.create(Kafka);
    errdefer container.allocator.destroy(c);

    c.mu = .{};
    c.signal = Atomic(bool).init(true);
    c.container = container;
    c.subscriber = std.array_list.Managed(kafkaSubscriber).init(container.allocator);

    const client: ?*kafkaClient = rdkafka.rd_kafka_new(
        mode,
        config,
        &c.err_message,
        c.err_message.len,
    );
    if (client == null) {
        const msg = try utils.combine(
            container.allocator,
            "could not create kafka subscriber {s}",
            .{c.err_message},
        );
        container.log.err(msg);
    }

    if (client != null) {
        const msg = try utils.combine(
            container.allocator,
            "kafka pubsub connected",
            .{},
        );
        container.log.info(msg);
    }

    c.client = client;
    c.topic = topic;
    c.kafkaMode = mode;
    c.isPubSubSet = true;

    return c;
}

pub fn getTopicHandler(self: *Self, ctx: *Context, name: []const u8) !*kafkaTopic {
    const topic_conf: ?*rdkafka.struct_rd_kafka_topic_conf_s = rdkafka.rd_kafka_topic_conf_new();

    var error_message: [512]u8 = undefined;
    const err_code = rdkafka.rd_kafka_topic_conf_set(
        topic_conf,
        "acks",
        "all",
        &error_message,
        error_message.len,
    );
    if (err_code != rdkafka.RD_KAFKA_CONF_OK) {
        const msg = try utils.combine(
            ctx.allocator,
            "failed to set topic config {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        );
        ctx.err(msg);
    }

    const topic = rdkafka.rd_kafka_topic_new(
        self.client,
        @constCast(name.ptr),
        topic_conf,
    );
    if (topic == null) {
        const msg = try utils.combine(
            ctx.allocator,
            "failed to create topic {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        );
        ctx.err(msg);
    }

    return topic.?;
}

pub fn destroy(self: *Self) void {
    const err_code: c_int = rdkafka.rd_kafka_flush(self.client, 60_000);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = try utils.combine(
            self.container.allocator,
            "failed to flush messages {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        );
        self.container.log.err(msg);
    }
    rdkafka.rd_kafka_destroy(self.client);

    self.signal.store(false, .release);
    self.thread.join();
}

pub fn publish(self: *Self, ctx: *Context, topic: *kafkaTopic, key: []const u8, payload: []const u8) !void {
    const message_ptr: ?*anyopaque = @constCast(payload.ptr);
    const key_ptr: ?*anyopaque = @constCast(key.ptr);

    const err_code: c_int = rdkafka.rd_kafka_produce(
        topic,
        rdkafka.RD_KAFKA_PARTITION_UA,
        rdkafka.RD_KAFKA_MSG_F_COPY,
        message_ptr,
        payload.len,
        key_ptr,
        key.len,
        null,
    );
    if (err_code == rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = try utils.combine(
            ctx.allocator,
            "Message published successfully!",
            .{},
        );

        ctx.info(msg);

        self.container.metricz.publisherSuccess(.{ .topic = self.getTopicName(topic) }) catch unreachable;
    } else {
        const msg = try utils.combine(
            ctx.allocator,
            "Failed to publish message: {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        );

        ctx.err(msg);
    }

    self.container.metricz.publisherTotal(.{ .topic = self.getTopicName(topic) }) catch unreachable;
}

pub inline fn wait(self: Self, comptime timeout_ms: u16) void {
    while (rdkafka.rd_kafka_outq_len(self._producer) > 0) {
        _ = rdkafka.rd_kafka_poll(self._producer, timeout_ms);
    }
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

pub fn readPayload(self: *Self, subscriber: kafkaSubscriber) !void {
    while (self.signal.load(.monotonic)) {
        const message_or_null = rdkafka.rd_kafka_consumer_poll(self.client, 1000);
        if (message_or_null) |message| {
            var msg = kafkaMessage.init(message);
            msg.payload = msg.getPayload();
            msg.topic = msg.getTopic();

            defer msg.deinit();

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

            // transform packet to client.response using std.json.parse.
            context.message2 = &msg;

            try subscriber.exec(context);

            self.commitOffset(context, msg);

            self.container.metricz.subscriberTotal(.{ .topic = msg.getTopic(), .consumer = "zero-consumer" }) catch unreachable;
        }
    }
}

fn subscriptions(self: *Self) !void {
    for (self.subscriber.items) |s| {
        std.Thread.sleep(std.time.ns_per_ms * 100);
        const err_code: c_int = rdkafka.rd_kafka_subscribe(self.client, s.topics);
        if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
            const msg = try utils.combine(
                self.container.allocator,
                "failed to kafka subscriber: {s}",
                .{rdkafka.rd_kafka_err2str(err_code)},
            );
            self.container.log.err(msg);
            return;
        }

        self.container.log.info("kafka consumer subscribed");
        const thread = Thread.spawn(.{}, Self.readPayload, .{ self, s }) catch |err| {
            self.container.log.any(err);
            return;
        };
        thread.join();
    }
}

pub fn commitOffset(self: *Self, ctx: *Context, message: kafkaMessage) void {
    const err_code: c_int = rdkafka.rd_kafka_commit_message(self.client, message._message, 1);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to commit offset {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch unreachable;
        ctx.err(msg);
        return;
    }
    const msg = utils.combine(ctx.allocator, "Offset {d} commited", .{message.getOffset()}) catch unreachable;
    ctx.info(msg);
}

pub inline fn unsubscribe(self: *Self, ctx: *Context) void {
    const err_code: c_int = rdkafka.rd_kafka_unsubscribe(self.client);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to unsubsribe {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch unreachable;
        ctx.err(msg);
        return;
    }
    ctx.info("consumer unsubscribed successfully.");
}

pub inline fn close(self: *Self, ctx: *Context) void {
    const err_code: c_int = rdkafka.rd_kafka_consumer_close(self._consumer);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to close {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch unreachable;
        ctx.err(msg);
        return;
    }
    ctx.info("Consumer closed successfully.");
}

pub fn startSubscription(self: *Self) !void {
    self.thread = Thread.spawn(.{}, Self.subscriptions, .{self}) catch |err| {
        self.container.log.any(err);
        return;
    };
}

pub fn addSubscriber(self: *Self, topic: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    const topics = [_][]const u8{topic};

    const _topics = rdkafka.rd_kafka_topic_partition_list_new(@intCast(topics.len));
    if (_topics == null) {
        const msg = utils.combine(self.container.allocator, "failed to create topic list", .{}) catch |err| {
            self.container.log.any(err);
            return;
        };
        self.container.log.info(msg);
    }

    for (topics) |topic_name| {
        _ = rdkafka.rd_kafka_topic_partition_list_add(_topics, @constCast(topic_name.ptr), rdkafka.RD_KAFKA_PARTITION_UA);
    }

    const s = kafkaSubscriber{
        .topics = _topics,
        .topic = topics[0],
        .name = topics[0],
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

inline fn getTopicName(_: *Self, topic: *kafkaTopic) []const u8 {
    const name: []const u8 = std.mem.span(rdkafka.rd_kafka_topic_name(topic));
    return name;
}
