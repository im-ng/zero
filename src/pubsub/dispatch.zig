const std = @import("std");
const root = @import("../zero.zig");
const constants = root.constants;

/// Outcome of dispatching one message to its subscriber hook(s). Backends use
/// this to decide whether to ACK/delete the message: only delete when `handled`.
pub const DispatchStatus = enum {
    /// The hook succeeded, or the message was successfully moved to a DLQ.
    handled,
    /// The hook failed and no DLQ accepted it; leave the message for native
    /// redelivery (the backend's own retry/DLQ policy).
    failed,
};

/// Runs a subscribe hook for one inbound message, delivering the message via
/// `context.message` and applying the same retry + dead-letter policy as the
/// Redis backend. Shared by the HTTP-based pub/sub backends (SQS, GCP Pub/Sub)
/// so the handler-dispatch machinery lives in one place.
pub fn runHook(
    container: *root.container,
    hook: *const fn (*root.Context) anyerror!void,
    message: root.pubsubInterface.Message,
) DispatchStatus {
    const allocator = container.allocator;
    const ca = allocator.create(std.heap.ArenaAllocator) catch return;
    ca.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        ca.deinit();
        allocator.destroy(ca);
    }

    // A valid, non-socket response for the subscriber hook's Context (audit #15):
    // an undefined `*httpz.Response` is UB if the hook touches it. Backed by the
    // per-message arena, freed when `ca` is deinited at the end of this function.
    const res = root.context.makeSyntheticResponse(ca.allocator()) catch return;
    var ctx = root.Context.init(ca.allocator(), container, null, res) catch return;
    const context = &ctx;
    context.message = message;

    // Each backend's message struct carries subject/payload under different
    // fields; extract them explicitly so this compiles for every variant.
    const extracted = switch (message) {
        .sqs => |m| .{ m.subject, m.payload },
        .gcp => |m| .{ m.subject, m.payload },
        .nats => |m| .{ m.subject, m.payload },
        .redis => |m| .{ m.subject, m.payload },
        .mqtt => |m| .{ @as([]const u8, ""), m.payload orelse "" },
        .kafka => |m| .{ @as([]const u8, ""), m.payload orelse "" },
    };
    const subject = extracted[0];
    const payload = extracted[1];

    var attempt: u32 = 0;
    const max_attempts: u32 = constants.DEFAULT_PUBSUB_MAX_ATTEMPTS;
    const backoff_ms: i64 = constants.DEFAULT_PUBSUB_BACKOFF_MS;
    while (attempt < max_attempts) : (attempt += 1) {
        hook(context) catch |err| {
            container.log.Any(allocator, err);
            if (attempt + 1 < max_attempts) {
                std.Io.sleep(container.io, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
                continue;
            }
            // Final failure. Native-DLQ backends (SQS/GCP) rely on their own
            // redrive policy; app-level republish would re-enter the same queue
            // and loop (audit #14). Leave the message for native redelivery.
            if (container.pubSub) |ps| {
                if (ps.native_dlq) {
                    container.metricz.dlq(.{ .topic = subject, .consumer = "dlq" }) catch {};
                    return .failed;
                }
            }
            const dlq = std.fmt.allocPrint(allocator, "{s}.dlq", .{subject}) catch return .failed;
            defer allocator.free(dlq);
            container.metricz.dlq(.{ .topic = subject, .consumer = "dlq" }) catch {};
            if (container.pubSub) |ps| {
                ps.Publish(dlq, payload) catch |dlerr| {
                    container.log.Any(allocator, dlerr);
                    return .failed;
                };
            }
            return .handled;
        };
        break;
    }
    return .handled;
}
