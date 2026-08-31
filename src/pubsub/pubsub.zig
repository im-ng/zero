const std = @import("std");
const root = @import("../zero.zig");

/// Unified pub/sub interface that dispatches to the configured backend
/// (MQTT, Kafka or NATS). Handlers can use `ctx.PubSub` without knowing
/// which backend is active or reading any configuration.
pub const PubSub = struct {
    backend: Backend,
    mqtt: ?*root.MQTT = null,
    kafka: ?*root.kafka = null,
    nats: ?*root.nats = null,

    pub const Backend = enum { mqtt, kafka, nats };

    pub fn Publish(self: *PubSub, subject: []const u8, payload: []const u8) !void {
        switch (self.backend) {
            .mqtt => _ = try self.mqtt.?.Publish(subject, payload),
            .kafka => try self.kafka.?.publishOnSubject(subject, payload),
            .nats => try self.nats.?.Publish(subject, payload),
        }
    }

    pub fn addSubscriber(self: *PubSub, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        switch (self.backend) {
            .mqtt => try self.mqtt.?.addSubscriber(subject, hook),
            .kafka => try self.kafka.?.addSubscriber(subject, hook),
            .nats => try self.nats.?.addSubscriber(subject, hook),
        }
    }
};
