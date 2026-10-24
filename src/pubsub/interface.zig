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
///
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
        publish: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        subscribe: *const fn (*anyopaque, []const u8, *const fn (*root.Context) anyerror!void) anyerror!void,
    };

    pub fn Publish(self: Interface, subject: []const u8, payload: []const u8) !void {
        return self.vtable.publish(self.ptr, subject, payload);
    }

    /// Bounded retry policy for outbound publishes (audit #32). On a transient
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
            self.vtable.publish(self.ptr, subject, payload) catch |err| {
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
