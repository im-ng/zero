const std = @import("std");
const root = @import("../../zero.zig");
pub const NATS = @This();
const Self = @This();

const nats = root.natslib;
const natsConfig = root.natsConfig;
const natsMessage = root.natsMessage;
const natsSubscriber = root.natsSubscriber;

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

allocator: std.mem.Allocator = undefined,
thread: std.Thread = undefined,
container: *root.container = undefined,
client: *nats.Client = undefined,
js: ?nats.jetstream.JetStream = null,
stream: ?nats.jetstream.PullSubscription = null,
subscriber: std.array_list.Managed(natsSubscriber) = undefined,
mu: std.Io.Mutex = undefined,
signal: Atomic(bool) = undefined,
isPubSubSet: bool = false,

pub fn create(container: *root.container, config: *const natsConfig) !*NATS {
    const c = try container.allocator.create(NATS);
    errdefer container.allocator.destroy(c);

    c.mu = .init;
    c.signal = Atomic(bool).init(true);
    c.container = container;
    c.subscriber = std.array_list.Managed(natsSubscriber).init(container.allocator);
    c.allocator = container.allocator;

    var opts = nats.Options{};
    if (config.creds_file.len > 0) {
        opts.creds_file = config.creds_file;
    }

    const client = try nats.Client.connect(container.allocator, container.io, config.url, opts);
    c.client = client;

    if (config.hasStream()) {
        c.js = try nats.jetstream.JetStream.init(client, .{});

        var subjects_buf: [8][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, config.subjects, ',');
        var count: usize = 0;
        while (it.next()) |s| {
            const trimmed = std.mem.trim(u8, s, " \t");
            if (trimmed.len == 0) continue;
            if (count >= subjects_buf.len) break;
            subjects_buf[count] = trimmed;
            count += 1;
        }
        const subjects = subjects_buf[0..count];

        _ = c.js.?.createStream(.{ .name = config.stream, .subjects = subjects }) catch |err| {
            // a stream with the same name may already exist; treat that as ok.
            if (err != error.StreamExists) {
                container.log.Any(container.allocator, err);
            }
        };

        _ = c.js.?.createOrUpdateConsumer(config.stream, .{
            .durable_name = config.consumer,
            .ack_policy = .all,
        }) catch |err| {
            container.log.Any(container.allocator, err);
            return err;
        };

        var ps = nats.jetstream.PullSubscription{ .js = &c.js.?, .stream = config.stream };
        try ps.setConsumer(config.consumer);
        c.stream = ps;
    }

    c.isPubSubSet = true;

    const msg = utils.combine(
        container.allocator,
        "connected to NATS at '{s}'",
        .{config.url},
    ) catch |err| {
        container.log.Any(container.allocator, err);
        return err;
    };

    container.log.info(msg);

    return c;
}

pub fn destroy(self: *Self) void {
    self.signal.store(false, .release);
    self.client.deinit();
    if (self.subscriber.items.len > 0) {
        self.thread.join();
    }
}

pub fn Publish(self: *Self, subject: []const u8, payload: []const u8) !void {
    return try self.client.publish(subject, payload);
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

fn dispatch(self: *Self, subject: []const u8, payload: []const u8, hook: *const fn (*root.Context) anyerror!void) void {
    const ca = self.prepareChildAllocator() catch |err| {
        self.container.log.Any(self.container.allocator, err);
        return;
    };
    defer self.destroryChildAllocator(ca);

    var ctx = Context.init(
        ca.allocator(),
        self.container,
        _req,
        _res,
    ) catch |err| {
        self.container.log.Any(self.container.allocator, err);
        return;
    };
    const context = &ctx;

    var message = natsMessage{
        .context = context,
        .subject = subject,
        .payload = payload,
    };
    context.message = .{ .nats = &message };

    // Retry the handler a few times; on a poison message, dead-letter it to
    // `<subject>.dlq`.
    var attempt: u32 = 0;
    const max_attempts: u32 = constants.DEFAULT_PUBSUB_MAX_ATTEMPTS;
    const backoff_ms: i64 = constants.DEFAULT_PUBSUB_BACKOFF_MS;
    while (attempt < max_attempts) : (attempt += 1) {
        hook(context) catch |err| {
            self.container.log.Any(self.allocator, err);
            if (attempt + 1 < max_attempts) {
                std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
                continue;
            }
            const dlq = std.fmt.allocPrint(self.allocator, "{s}.dlq", .{subject}) catch break;
            defer self.allocator.free(dlq);
            self.container.metricz.dlq(.{ .topic = subject, .consumer = "dlq" }) catch {};
            self.Publish(dlq, payload) catch |dlerr| self.container.log.Any(self.allocator, dlerr);
            break;
        };
        break;
    }
}

fn readJetStream(self: *Self, sub: natsSubscriber) !void {
    while (self.signal.load(.monotonic)) {
        var result = self.stream.?.fetch(.{
            .max_messages = 1,
            .timeout_ms = self.container.natsPullWaitMs(),
        }) catch |err| {
            if (err == error.NoHeartbeat) {
                continue;
            }
            self.container.log.Any(self.container.allocator, err);
            // The nats client reconnects automatically; pause and retry rather than
            // abandoning the stream consumer.
            std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
            continue;
        };
        defer result.deinit();

        if (result.count() == 0) continue;

        var msg = result.messages[0];
        const subject = msg.subject();
        const payload = msg.data();
        self.dispatch(subject, payload, sub.exec);
        msg.ack() catch {};
        // NOTE: do not call msg.deinit() here — result.deinit() (deferred above)
        // owns and frees all JsMsg buffers. Calling it again double-frees.
    }
}

fn readCore(self: *Self, sub: natsSubscriber) !void {
    while (self.signal.load(.monotonic)) {
        // (Re)subscribe; on a dropped connection the subscription is gone so we
        // re-establish it each time the inner loop bails out on error.
        const s = self.client.subscribeSync(sub.topic) catch |err| {
            self.container.log.Any(self.container.allocator, err);
            std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
            continue;
        };
        while (self.signal.load(.monotonic)) {
            std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            const msg = s.tryNextMsg() orelse continue;
            self.dispatch(msg.subject, msg.data, sub.exec);
            msg.deinit();
        }
        break;
    }
}

fn subscriptions(self: *Self) !void {
    for (self.subscriber.items) |client| {
        if (self.stream != null) {
            try self.readJetStream(client);
        } else {
            try self.readCore(client);
        }
    }
}

pub fn startSubscription(self: *Self) !void {
    self.thread = Thread.spawn(.{}, Self.subscriptions, .{self}) catch |err| {
        self.container.log.Any(self.container.allocator, err);
        return;
    };
}

pub fn addSubscriber(self: *Self, topic: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    const s = natsSubscriber{
        .topic = topic,
        .name = topic,
        .exec = hook,
    };

    self.mu.lock(self.container.io) catch {};
    try self.subscriber.append(s);
    self.mu.unlock(self.container.io);

    const msg = utils.combine(
        self.container.allocator,
        "topic:{s} nats subscriber added",
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
            const self: *NATS = @ptrCast(@alignCast(ptr));
            try self.Publish(subject, payload);
        }
    }.call,
    .subscribe = struct {
        fn call(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
            const self: *NATS = @ptrCast(@alignCast(ptr));
            try self.addSubscriber(subject, hook);
        }
    }.call,
};
