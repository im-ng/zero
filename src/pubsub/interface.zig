const std = @import("std");
const root = @import("../zero.zig");

/// Unified inbound message. A tagged union over the per-backend message
/// types so subscribe hooks can read the payload regardless of backend.
pub const Message = union(enum) {
    mqtt: *root.mqMessage,
    kafka: *root.kafkaMessage,
    nats: *root.natsMessage,
};

/// Unified pub/sub interface (type-erased VTable).
///
/// Wraps any configured backend (MQTT, Kafka, NATS) behind a stable
/// function-pointer table. Handler code uses `ctx.pubsub.Publish(...)` /
/// `ctx.pubsub.subscribe(...)` without knowing or reading the backend.
pub const Interface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        publish: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        subscribe: *const fn (*anyopaque, []const u8, *const fn (*root.Context) anyerror!void) anyerror!void,
    };

    pub fn Publish(self: Interface, subject: []const u8, payload: []const u8) !void {
        return self.vtable.publish(self.ptr, subject, payload);
    }

    pub fn subscribe(self: Interface, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        return self.vtable.subscribe(self.ptr, subject, hook);
    }

    /// Alias for `subscribe`, matching the app-level `addPubSubSubscription` naming.
    pub fn addSubscriber(self: Interface, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        return self.subscribe(subject, hook);
    }
};
