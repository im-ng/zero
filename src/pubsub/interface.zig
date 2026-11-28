const std = @import("std");
const root = @import("../zero.zig");

/// Unified inbound message. A tagged union over the per-backend message
/// types so subscribe hooks can read the payload regardless of backend.
pub const Message = union(enum) {
    mqtt: *root.mqMessage,
    kafka: *root.kafkaMessage,
    nats: *root.natsMessage,
    redis: *root.redisMessage,
    sqs: *root.sqsMessage,
    gcp: *root.gcpMessage,
};

/// Unified pub/sub interface (type-erased VTable).
/// Wraps any configured backend (MQTT, Kafka, NATS) behind a stable
/// function-pointer table. Handler code uses `ctx.pubsub.Publish(...)` /
/// `ctx.pubsub.subscribe(...)` without knowing or reading the backend.
pub const Interface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Backends with a native dead-letter mechanism (SQS redrive policy, GCP
    /// dead-letter subscriptions) set this so `dispatch.runHook` does NOT also
    /// do an app-level DLQ republish. The app-level republish posts to
    /// `<subject>.dlq`, which for a single-queue SQS client would re-enter the
    /// same queue and loop forever.
    native_dlq: bool = false,

    pub const VTable = struct {
        /// Publishes `payload` to `subject`. `key` is the optional partition
        /// key: Kafka uses it to keep related messages on the same partition.
        /// Backends without partitioning ignore it.
        publish: *const fn (*anyopaque, []const u8, []const u8, ?[]const u8) anyerror!void,
        subscribe: *const fn (*anyopaque, []const u8, *const fn (*root.Context) anyerror!void) anyerror!void,
    };

    /// Publish without a partition key. Preserved for existing callers.
    pub fn Publish(self: Interface, subject: []const u8, payload: []const u8) !void {
        return self.vtable.publish(self.ptr, subject, payload, null);
    }

    /// Publish with a partition key. Kafka routes messages with the same key
    /// to the same partition, preserving order. Other backends ignore the key.
    pub fn PublishWithKey(
        self: Interface,
        subject: []const u8,
        payload: []const u8,
        key: ?[]const u8,
    ) !void {
        return self.vtable.publish(self.ptr, subject, payload, key);
    }

    /// Bounded retry policy for outbound publishes. On a transient
    /// publish failure, retries up to `attempts` times, sleeping `backoff_ms`
    /// between tries. `attempts == 1` (the default) is equivalent to `Publish`.
    /// The caller's `io` is required so the backoff can suspend the task.
    pub const RetryOptions = struct {
        attempts: usize = 1,
        backoff_ms: u64 = 0,
    };

    pub fn PublishRetrying(
        self: Interface,
        io: std.Io,
        subject: []const u8,
        payload: []const u8,
        opts: RetryOptions,
    ) !void {
        var attempt: usize = 0;
        while (attempt < opts.attempts) : (attempt += 1) {
            self.vtable.publish(self.ptr, subject, payload, null) catch |err| {
                if (attempt + 1 < opts.attempts and opts.backoff_ms > 0) {
                    std.Io.Timeout.sleep(
                        .{ .duration = std.Io.Duration.fromMilliseconds(opts.backoff_ms) },
                        io,
                    ) catch {};
                }
                if (attempt + 1 >= opts.attempts) return err;
                continue;
            };
            return;
        }
    }

    pub fn subscribe(self: Interface, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        return self.vtable.subscribe(self.ptr, subject, hook);
    }

    /// Alias for `subscribe`, matching the app-level `addPubSubSubscription` naming.
    pub fn addSubscriber(self: Interface, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        return self.subscribe(subject, hook);
    }
};

test "publish forwards the partition key through the vtable" {
    const Recorder = struct {
        var key_seen: ?[]const u8 = null;
        var subject_seen: []const u8 = "";

        fn publish(
            ptr: *anyopaque,
            subject: []const u8,
            _: []const u8,
            key: ?[]const u8,
        ) anyerror!void {
            _ = ptr;
            subject_seen = subject;
            key_seen = key;
        }
        fn subscribe(_: *anyopaque, _: []const u8, _: *const fn (*root.Context) anyerror!void) anyerror!void {}
    };

    var state: u8 = 0;
    const vtable = Interface.VTable{ .publish = Recorder.publish, .subscribe = Recorder.subscribe };
    const iface = Interface{ .ptr = &state, .vtable = &vtable };

    try iface.PublishWithKey("orders", "{}", "customer-42");
    try std.testing.expectEqualStrings("orders", Recorder.subject_seen);
    try std.testing.expectEqualStrings("customer-42", Recorder.key_seen.?);

    // The legacy Publish path must still forward null.
    try iface.Publish("orders", "{}");
    try std.testing.expect(Recorder.key_seen == null);
}
