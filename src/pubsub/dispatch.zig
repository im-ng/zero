const std = @import("std");
const root = @import("../zero.zig");
const constants = root.constants;

/// Runs a subscribe hook for one inbound message, delivering the message via
/// `context.message` and applying the same retry + dead-letter policy as the
/// Redis backend. Shared by the HTTP-based pub/sub backends (SQS, GCP Pub/Sub)
/// so the handler-dispatch machinery lives in one place.
pub fn runHook(
    container: *root.container,
    hook: *const fn (*root.Context) anyerror!void,
    message: root.pubsubInterface.Message,
) void {
    const allocator = container.allocator;
    const ca = allocator.create(std.heap.ArenaAllocator) catch return;
    ca.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        ca.deinit();
        allocator.destroy(ca);
    }

    var ctx = root.Context.init(ca.allocator(), container, null, @as(*root.httpz.Response, undefined)) catch return;
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
            const dlq = std.fmt.allocPrint(allocator, "{s}.dlq", .{subject}) catch break;
            defer allocator.free(dlq);
            container.metricz.dlq(.{ .topic = subject, .consumer = "dlq" }) catch {};
            if (container.pubSub) |ps| {
                ps.Publish(dlq, payload) catch |dlerr| container.log.Any(allocator, dlerr);
            }
            break;
        };
        break;
    }
}
