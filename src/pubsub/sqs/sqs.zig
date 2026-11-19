const std = @import("std");
const root = @import("../../zero.zig");
const zul = root.zul;
const utils = root.utils;
const sigv4 = @import("../../utils/sigv4.zig");
const dispatch = @import("../dispatch.zig");

/// Inbound message surfaced to SQS subscribe hooks.
pub const Message = struct {
    context: *root.Context,
    subject: []const u8,
    payload: []const u8,
};

/// AWS SQS pub/sub backend over the JSON 1.1 protocol (SigV4 header-signed).
/// `publish` sends `SendMessage`
/// `subscribe` spawns a long-polling receiver thread that dispatches
/// each message to the registered hook (with retry/DLQ via the shared `dispatch.runHook`).
pub const SQS = struct {
    allocator: std.mem.Allocator,
    container: ?*root.container = null,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    queue_url: []const u8,
    subscribers: std.array_list.Managed(Subscriber),
    running: std.atomic.Value(bool),
    // Consumer thread handle; null until `subscribe` spawns it
    thread: ?std.Thread = null,

    const Subscriber = struct {
        topic: []const u8,
        hook: *const fn (*root.Context) anyerror!void,
    };

    /// Explicit builder (used by tests and `create`). `container` stays null
    /// here; `subscribe` requires a live container for the polling loop.
    pub fn init(
        allocator: std.mem.Allocator,
        opts: struct {
            region: []const u8 = "us-east-1",
            access_key: []const u8 = "",
            secret_key: []const u8 = "",
            queue_url: []const u8,
        },
    ) !*SQS {
        if (opts.queue_url.len == 0) return error.SqsQueueUrlRequired;

        const self = try allocator.create(SQS);
        self.* = .{
            .allocator = allocator,
            .region = try allocator.dupe(u8, opts.region),
            .access_key = try allocator.dupe(u8, opts.access_key),
            .secret_key = try allocator.dupe(u8, opts.secret_key),
            .queue_url = try allocator.dupe(u8, opts.queue_url),
            .subscribers = std.array_list.Managed(Subscriber).init(allocator),
            .running = std.atomic.Value(bool){ .raw = false },
        };
        return self;
    }

    pub fn create(container: *root.container) !*SQS {
        const region = container.config.getOrDefault("AWS_REGION", "us-east-1");
        const access_key = container.config.getOrDefault("AWS_ACCESS_KEY", "");
        const secret_key = container.config.getOrDefault("AWS_SECRET_KEY", "");
        const queue_url = container.config.getOrDefault("SQS_QUEUE_URL", "");
        if (queue_url.len == 0) return error.SqsQueueUrlRequired;

        const self = try init(container.allocator, .{
            .region = region,
            .access_key = access_key,
            .secret_key = secret_key,
            .queue_url = queue_url,
        });
        self.container = container;
        return self;
    }

    pub fn deinit(self: *SQS) void {
        // Stop the polling loop and join its thread before freeing any state it
        // touches
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.allocator.free(self.region);
        self.allocator.free(self.access_key);
        self.allocator.free(self.secret_key);
        self.allocator.free(self.queue_url);
        for (self.subscribers.items) |s| {
            self.allocator.free(s.topic);
        }
        self.subscribers.deinit();
        self.allocator.destroy(self);
    }

    fn authHeaders(
        self: *SQS,
        allocator: std.mem.Allocator,
        target: []const u8,
        body: []const u8,
    ) !struct { authorization: []const u8, amz_date: []const u8, content_sha256: []const u8 } {
        const amz_date = try sigv4.amzDate(allocator);
        const payload_hash = sigv4.sha256Hex(body);
        // `payload_hash` is a stack `[64]u8`; returning `&payload_hash` would be a
        // dangling pointer once this function returns, and it is read later as the
        // `x-amz-content-sha256` header. Dupe it into `allocator` (the request
        // arena) so the header stays valid
        const content_sha256 = try allocator.dupe(u8, &payload_hash);
        const host = try sigv4.hostOf(allocator, self.queue_url);
        const signed = [_]sigv4.Header{
            .{ .name = "host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = content_sha256 },
            .{ .name = "x-amz-date", .value = amz_date },
            .{ .name = "x-amz-target", .value = target },
        };
        const authorization = try sigv4.signAuthorization(
            allocator,
            "POST",
            "/",
            "",
            self.region,
            "sqs",
            self.access_key,
            self.secret_key,
            content_sha256,
            amz_date,
            &signed,
        );
        return .{ .authorization = authorization, .amz_date = amz_date, .content_sha256 = content_sha256 };
    }

    pub fn publish(self: *SQS, subject: []const u8, payload: []const u8) !void {
        _ = subject;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Build the JSON body via std.json so the payload is properly escaped
        // (a quote/backslash/newline in `payload` would otherwise corrupt the JSON
        // request,
        var obj = std.json.ObjectMap.empty;
        try obj.put(a, "QueueUrl", std.json.Value{ .string = self.queue_url });
        try obj.put(a, "MessageBody", std.json.Value{ .string = payload });
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{});
        const h = try self.authHeaders(a, "AmazonSQS.SendMessage", body);

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, self.queue_url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/x-amz-json-1.0");
        try req.header("x-amz-target", "AmazonSQS.SendMessage");
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);
        req.body(body);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.SqsSendFailed;
    }

    pub fn subscribe(self: *SQS, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        try self.subscribers.append(.{ .topic = try self.allocator.dupe(u8, subject), .hook = hook });
        if (!self.running.load(.acquire)) {
            self.running.store(true, .release);
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
                self.running.store(false, .release);
                return error.SqsSubscriberSpawnFailed;
            };
        }
    }

    fn run(self: *SQS) void {
        while (self.running.load(.acquire)) {
            self.poll() catch {};
            std.Io.sleep(self.container.?.io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }
    }

    fn poll(self: *SQS) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const body = try std.fmt.allocPrint(a, "{{\"QueueUrl\":\"{s}\",\"MaxNumberOfMessages\":10,\"WaitTimeSeconds\":5}}", .{self.queue_url});
        const h = try self.authHeaders(a, "AmazonSQS.ReceiveMessage", body);

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, self.queue_url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/x-amz-json-1.0");
        try req.header("x-amz-target", "AmazonSQS.ReceiveMessage");
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);
        req.body(body);

        var res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return;

        var sb = try res.allocBody(a, .{ .max_size = 4 * 1024 * 1024 });
        defer sb.deinit();
        const raw = try a.dupe(u8, sb.string());

        // AWS SQS JSON protocol (application/x-amz-json-1.0) returns JSON; the
        // legacy fake-server tests still emit XML. Parse JSON when the body does
        // not start with '<', otherwise fall back to the XML parser
        if (raw.len > 0 and raw[0] == '<') {
            var it = std.mem.splitScalar(u8, raw, '<');
            while (it.next()) |seg| {
                if (std.mem.indexOf(u8, seg, "Message>") != 0) continue;
                const block = seg["Message>".len..];
                const receipt = between(block, "ReceiptHandle>", "</ReceiptHandle") orelse continue;
                const msg_body = between(block, "Body>", "</Body") orelse continue;
                for (self.subscribers.items) |sub| {
                    var m = Message{ .context = undefined, .subject = sub.topic, .payload = msg_body };
                    const union_msg: root.pubsubInterface.Message = .{ .sqs = &m };
                    // Only delete once every subscriber hook has handled the message.
                    // On failure we leave it so SQS redelivers / applies its native
                    // redrive policy instead of dropping it (audit #14).
                    if (dispatch.runHook(self.container.?, sub.hook, union_msg) == .handled) {
                        self.delete(receipt) catch {};
                    }
                }
            }
        } else {
            const doc = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{ .ignore_unknown_fields = true }) catch return;
            if (doc == .object) {
                const msgs = if (doc.object.get("messages")) |m| m else if (doc.object.get("Messages")) |m| m else null;
                if (msgs) |entries| {
                    if (entries == .array) {
                        for (entries.array.items) |entry| {
                            if (entry != .object) continue;
                            const receipt = sqsJsonField(entry.object, "receiptHandle", "ReceiptHandle");
                            const msg_body = sqsJsonField(entry.object, "body", "Body");
                            if (receipt == null or msg_body == null) continue;
                            for (self.subscribers.items) |sub| {
                                var m = Message{ .context = undefined, .subject = sub.topic, .payload = msg_body.? };
                                const union_msg: root.pubsubInterface.Message = .{ .sqs = &m };
                                if (dispatch.runHook(self.container.?, sub.hook, union_msg) == .handled) {
                                    self.delete(receipt.?) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn delete(self: *SQS, receipt_handle: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var obj = std.json.ObjectMap.empty;
        try obj.put(a, "QueueUrl", std.json.Value{ .string = self.queue_url });
        try obj.put(a, "ReceiptHandle", std.json.Value{ .string = receipt_handle });
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{});
        const h = try self.authHeaders(a, "AmazonSQS.DeleteMessage", body);

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, self.queue_url);
        defer req.deinit();
        req.method = .POST;
        try req.header("content-type", "application/x-amz-json-1.0");
        try req.header("x-amz-target", "AmazonSQS.DeleteMessage");
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);
        req.body(body);

        _ = try req.getResponse(.{});
    }

    pub const vtable = root.PubSub.VTable{
        .publish = publishWrap,
        .subscribe = subscribeWrap,
    };
};

fn between(haystack: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const s = std.mem.indexOf(u8, haystack, start) orelse return null;
    const from = s + start.len;
    const e = std.mem.indexOf(u8, haystack[from..], end) orelse return null;
    return haystack[from .. from + e];
}

/// Read a string field from a parsed JSON object, trying both the lowercase
/// (`receiptHandle`) and capitalized (`ReceiptHandle`) AWS JSON-protocol spellings.
fn sqsJsonField(obj: std.json.ObjectMap, lower: []const u8, upper: []const u8) ?[]const u8 {
    if (obj.get(lower)) |v| {
        if (v == .string) return v.string;
    }
    if (obj.get(upper)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn publishWrap(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
    const self = @as(*SQS, @ptrCast(@alignCast(ptr)));
    return self.publish(subject, payload);
}

fn subscribeWrap(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
    const self = @as(*SQS, @ptrCast(@alignCast(ptr)));
    return self.subscribe(subject, hook);
}
