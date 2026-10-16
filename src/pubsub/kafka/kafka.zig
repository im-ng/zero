const std = @import("std");
const root = @import("../../zero.zig");
const Kafka = @This();
const Self = @This();

const kConfig = root.kConfig;
const rdkafka = root.rdkafka;
const kafkaSubscriber = root.kafkaSubscriber;
const kafkaMessage = root.kafkaMessage;
const tracz = root.tracz;

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

const _req: ?*httpz.Request = null;
const _res: *httpz.Response = undefined;

thread: std.Thread = undefined,
container: *root.container = undefined,
rootContext: *root.Context = undefined,
mu: std.Io.Mutex = undefined,
signal: Atomic(bool) = undefined,
config: ?*kafkaConfig,
topic: ?*kafkaTopic,
client: ?*kafkaClient,
subscriber: std.array_list.Managed(kafkaSubscriber) = undefined,
subscriber_by_topic: std.StringHashMap(*kafkaSubscriber) = undefined,
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

    c.mu = .init;
    c.signal = Atomic(bool).init(true);
    c.container = container;
    c.subscriber = std.array_list.Managed(kafkaSubscriber).init(container.allocator);
    c.subscriber_by_topic = std.StringHashMap(*kafkaSubscriber).init(container.allocator);

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
    // Signal the consumer thread to stop FIRST, then join it. Blocking on the
    // client (flush/destroy) before the consumer poll loop has exited would
    // deadlock join() and hang process shutdown.
    self.signal.store(false, .release);
    if (self.kafkaMode == root.rdkafka.RD_KAFKA_CONSUMER) {
        self.thread.join();
    }

    self.subscriber_by_topic.deinit();

    // Only producers have pending messages to flush; flushing a consumer
    // returns "Not implemented" and is meaningless here.
    if (self.kafkaMode != root.rdkafka.RD_KAFKA_CONSUMER) {
        const err_code: c_int = rdkafka.rd_kafka_flush(self.client, constants.DEFAULT_KAFKA_FLUSH_MS);
        if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
            const msg = utils.combine(
                self.container.allocator,
                "failed to flush messages {s}",
                .{rdkafka.rd_kafka_err2str(err_code)},
            ) catch "failed to flush kafka messages";
            self.container.log.err(msg);
        }
    }
    rdkafka.rd_kafka_destroy(self.client);
}

pub fn publish(self: *Self, ctx: *Context, topic: *kafkaTopic, key: []const u8, payload: []const u8) !void {
    const message_ptr: ?*anyopaque = @constCast(payload.ptr);
    const key_ptr: ?*anyopaque = @constCast(key.ptr);

    // Propagate the inbound correlation id and the active OpenTelemetry trace
    // as Kafka record headers when present. ctx.request is only set during an
    // HTTP request; cron/pub-sub driven publishes have no request, so guard
    // against a null request. The traceparent continues the trace across the
    // async boundary so the consumer can parent a span to the upstream.
    const cid = if (ctx.request) |r| r.header("X-Correlation-ID") else null;
    const tp = tracz.currentTraceparent(ctx.allocator);
    defer if (tp) |t| ctx.allocator.free(t);

    const err_code: c_int = blk: {
        if (cid != null or tp != null) {
            const hdrs = rdkafka.rd_kafka_headers_new(2);
            if (cid) |id| {
                _ = rdkafka.rd_kafka_header_add(hdrs, "X-Correlation-ID", -1, id.ptr, @intCast(id.len));
            }
            if (tp) |t| {
                _ = rdkafka.rd_kafka_header_add(hdrs, "traceparent", -1, t.ptr, @intCast(t.len));
            }
            const rc = rdkafka.rd_kafka_producev(
                self.client.?,
                topic,
                rdkafka.RD_KAFKA_PARTITION_UA,
                rdkafka.RD_KAFKA_MSG_F_COPY,
                rdkafka.RD_KAFKA_VTYPE_VALUE,
                message_ptr,
                payload.len,
                rdkafka.RD_KAFKA_VTYPE_KEY,
                key_ptr,
                key.len,
                rdkafka.RD_KAFKA_VTYPE_HEADERS,
                hdrs,
                rdkafka.RD_KAFKA_VTYPE_END,
            );
            rdkafka.rd_kafka_headers_destroy(hdrs);
            break :blk rc;
        }
        break :blk rdkafka.rd_kafka_produce(
            topic,
            rdkafka.RD_KAFKA_PARTITION_UA,
            rdkafka.RD_KAFKA_MSG_F_COPY,
            message_ptr,
            payload.len,
            key_ptr,
            key.len,
            null,
        );
    };
    if (err_code == rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = try utils.combine(
            ctx.allocator,
            "Message published successfully!",
            .{},
        );

        ctx.info(msg);

        self.container.metricz.publisherSuccess(.{ .topic = self.getTopicName(topic) }) catch |e| std.debug.print("kafka publisherSuccess metric failed: {}\n", .{e});
    } else {
        const msg = try utils.combine(
            ctx.allocator,
            "Failed to publish message: {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        );

        ctx.err(msg);
    }

    self.container.metricz.publisherTotal(.{ .topic = self.getTopicName(topic) }) catch |e| std.debug.print("kafka publisherTotal metric failed: {}\n", .{e});
}

/// Convenience for the unified `PubSub` interface: publish to a subject
/// using a throwaway context (Kafka's `publish` requires a `*Context`).
pub fn publishOnSubject(self: *Self, subject: []const u8, payload: []const u8) !void {
    const ca = self.prepareChildAllocator() catch |err| {
        self.container.log.any(err);
        return;
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

    const topic = self.getTopicHandler(context, subject) catch |err| {
        self.container.log.any(err);
        return;
    };
    defer rdkafka.rd_kafka_topic_destroy(topic);

    try self.publish(context, topic, "", payload);
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

/// Run the registered handler for one message, retrying on failure and
/// dead-lettering poison messages to `<topic>__dlq` before committing.
fn processMessage(self: *Self, context: *Context, msg: *kafkaMessage, subscriber: kafkaSubscriber) void {
    // Continue the upstream trace across the async boundary: extract the
    // traceparent injected at publish time and parent a consume span to it so
    // the consumer's work shows up under the original request's trace.
    const tp = msg.getHeader("traceparent");
    const span = tracz.startConsumeSpan(self.container.allocator, self.container.otel, tp);
    defer tracz.endConsumeSpan(self.container.otel, span);

    // transform packet to client.response using std.json.parse.
    context.message = .{ .kafka = msg };

    // Retry the handler a few times; on a poison message, dead-letter it to
    // `<topic>__dlq` before committing the offset so it isn't silently lost.
    var attempt: u32 = 0;
    const max_attempts: u32 = constants.DEFAULT_PUBSUB_MAX_ATTEMPTS;
    const backoff_ms: i64 = constants.DEFAULT_PUBSUB_BACKOFF_MS;
    while (attempt < max_attempts) : (attempt += 1) {
        subscriber.exec(context) catch |err| {
            self.container.log.Any(self.container.allocator, err);
            if (attempt + 1 < max_attempts) {
                std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
                continue;
            }
            const dlq = std.fmt.allocPrint(self.container.allocator, "{s}__dlq", .{msg.topic}) catch return;
            defer self.container.allocator.free(dlq);
            self.container.metricz.dlq(.{ .topic = msg.topic, .consumer = "dlq" }) catch {};
            self.publishOnSubject(dlq, msg.payload orelse &[_]u8{}) catch |dlerr| {
                self.container.log.Any(self.container.allocator, dlerr);
            };
            break;
        };
        break;
    }

    self.commitOffset(context, msg.*);

    self.container.metricz.subscriberTotal(.{ .topic = msg.topic, .consumer = "zero-consumer" }) catch |e| std.debug.print("kafka subscriberTotal metric failed: {}\n", .{e});
}

fn subscriptions(self: *Self) !void {
    // rdkafka's consumer subscribes to a single topic list on the shared
    // client; calling subscribe per-subscriber *replaces* the prior list, so
    // only the last registered topic would ever be serviced. Instead, union
    // every registered topic into one list, subscribe ONCE, and dispatch each
    // incoming message to the subscriber that owns its topic.
    if (self.subscriber.items.len == 0) return;

    const combined = rdkafka.rd_kafka_topic_partition_list_new(@intCast(self.subscriber.items.len));
    if (combined == null) {
        self.container.log.err("failed to allocate kafka topic list");
        return;
    }

    var dedupe = std.StringHashMap(void).init(self.container.allocator);
    defer dedupe.deinit();

    for (self.subscriber.items) |*s| {
        if (!dedupe.contains(s.topic)) {
            dedupe.put(s.topic, {}) catch {};
            _ = rdkafka.rd_kafka_topic_partition_list_add(
                combined,
                @constCast(s.topic.ptr),
                rdkafka.RD_KAFKA_PARTITION_UA,
            );
        }
        // Map topic -> owning subscriber for dispatch. Last registration for a
        // topic wins, preserving the prior single-topic semantics.
        self.subscriber_by_topic.put(s.topic, s) catch |err| self.container.log.any(err);
    }

    const err_code: c_int = rdkafka.rd_kafka_subscribe(self.client, combined);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(
            self.container.allocator,
            "failed to kafka subscriber: {s}",
            .{rdkafka.rd_kafka_err2str(err_code)},
        ) catch "failed to kafka subscribe";
        self.container.log.err(msg);
        rdkafka.rd_kafka_topic_partition_list_destroy(combined);
        return;
    }
    rdkafka.rd_kafka_topic_partition_list_destroy(combined);

    self.container.log.info("kafka consumer subscribed");

    // A single shared consumer loop services every subscribed topic.
    while (self.signal.load(.monotonic)) {
        const message_or_null = rdkafka.rd_kafka_consumer_poll(self.client, 1000);
        if (message_or_null) |message| {
            var msg = kafkaMessage.init(message);
            msg.payload = msg.getPayload();
            msg.topic = msg.getTopic();

            defer msg.deinit();

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

            // Dispatch to the subscriber that registered this topic. With no
            // handler we still commit so the message isn't redelivered.
            const sub_ptr = self.subscriber_by_topic.get(msg.topic) orelse {
                self.commitOffset(context, msg);
                continue;
            };

            self.processMessage(context, &msg, sub_ptr.*);
        }
    }
}

pub fn commitOffset(self: *Self, ctx: *Context, message: kafkaMessage) void {
    const err_code: c_int = rdkafka.rd_kafka_commit_message(self.client, message._message, 1);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to commit offset {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch "failed to commit offset";
        ctx.err(msg);
        return;
    }
    const msg = utils.combine(ctx.allocator, "Offset {d} commited", .{message.getOffset()}) catch "offset committed";
    ctx.info(msg);
}

pub inline fn unsubscribe(self: *Self, ctx: *Context) void {
    const err_code: c_int = rdkafka.rd_kafka_unsubscribe(self.client);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to unsubsribe {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch "failed to unsubscribe";
        ctx.err(msg);
        return;
    }
    ctx.info("consumer unsubscribed successfully.");
}

pub inline fn close(self: *Self, ctx: *Context) void {
    const err_code: c_int = rdkafka.rd_kafka_consumer_close(self._consumer);
    if (err_code != rdkafka.RD_KAFKA_RESP_ERR_NO_ERROR) {
        const msg = utils.combine(ctx.allocator, "failed to close {s}", .{rdkafka.rd_kafka_err2str(err_code)}) catch "failed to close consumer";
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

    self.mu.lock(self.container.io) catch {};
    try self.subscriber.append(s);
    self.mu.unlock(self.container.io);

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

/// Type-erased VTable conforming to `pubsubInterface.Interface.VTable`.
pub const vtable = root.pubsubInterface.Interface.VTable{
    .publish = struct {
        fn call(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
            const self: *Kafka = @ptrCast(@alignCast(ptr));
            try self.publishOnSubject(subject, payload);
        }
    }.call,
    .subscribe = struct {
        fn call(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
            const self: *Kafka = @ptrCast(@alignCast(ptr));
            try self.addSubscriber(subject, hook);
        }
    }.call,
};
