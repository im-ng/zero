const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;
const dispatch = @import("dispatch.zig");

/// Inbound message surfaced to GCP Pub/Sub subscribe hooks.
pub const Message = struct {
    context: *root.Context,
    subject: []const u8,
    payload: []const u8,
};

/// GCP Pub/Sub backend over the REST API, authenticated with an OAuth2 bearer
/// token (fetched via the shared `gcp_oauth` client-credentials helper).
/// `publish` posts to `topics/<topic>:publish`; `subscribe` spawns a polling
/// Pull loop that dispatches each message and acknowledges it.
pub const GCP = struct {
    allocator: std.mem.Allocator,
    container: ?*root.container = null,
    project: []const u8,
    endpoint: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: []const u8,
    access_token_override: []const u8,
    token: ?[]const u8 = null,
    token_expires_at_ns: i128 = 0,
    subscription: []const u8,
    subscribers: std.array_list.Managed(Subscriber),
    running: std.atomic.Value(bool),

    const Subscriber = struct {
        topic: []const u8,
        hook: *const fn (*root.Context) anyerror!void,
    };

    /// Explicit builder (used by tests and `create`). `container` stays null
    /// here; `subscribe` requires a live container for the polling loop.
    pub fn init(
        allocator: std.mem.Allocator,
        opts: struct {
            project: []const u8,
            endpoint: []const u8 = "https://pubsub.googleapis.com",
            token_url: []const u8 = "https://oauth2.googleapis.com/token",
            client_id: []const u8 = "",
            client_secret: []const u8 = "",
            scope: []const u8 = "https://www.googleapis.com/auth/pubsub",
            access_token_override: []const u8 = "",
            subscription: []const u8 = "",
        },
    ) !*GCP {
        if (opts.project.len == 0) return error.GcpProjectRequired;

        const self = try allocator.create(GCP);
        self.* = .{
            .allocator = allocator,
            .project = try allocator.dupe(u8, opts.project),
            .endpoint = try allocator.dupe(u8, opts.endpoint),
            .token_url = try allocator.dupe(u8, opts.token_url),
            .client_id = try allocator.dupe(u8, opts.client_id),
            .client_secret = try allocator.dupe(u8, opts.client_secret),
            .scope = try allocator.dupe(u8, opts.scope),
            .access_token_override = try allocator.dupe(u8, opts.access_token_override),
            .subscription = try allocator.dupe(u8, opts.subscription),
            .subscribers = std.array_list.Managed(Subscriber).init(allocator),
            .running = std.atomic.Value(bool){ .raw = false },
        };
        return self;
    }

    pub fn create(container: *root.container) !*GCP {
        const project = container.config.getOrDefault("GCP_PROJECT", "");
        if (project.len == 0) return error.GcpProjectRequired;
        const subscription = container.config.getOrDefault("GCP_SUBSCRIPTION", "");
        if (subscription.len == 0) return error.GcpSubscriptionRequired;

        const self = try init(container.allocator, .{
            .project = project,
            .endpoint = container.config.getOrDefault("GCP_ENDPOINT", "https://pubsub.googleapis.com"),
            .token_url = container.config.getOrDefault("GCP_TOKEN_URL", "https://oauth2.googleapis.com/token"),
            .client_id = container.config.getOrDefault("GCP_CLIENT_ID", ""),
            .client_secret = container.config.getOrDefault("GCP_CLIENT_SECRET", ""),
            .scope = container.config.getOrDefault("GCP_SCOPE", "https://www.googleapis.com/auth/pubsub"),
            .access_token_override = container.config.getOrDefault("GCP_ACCESS_TOKEN", ""),
            .subscription = subscription,
        });
        self.container = container;
        return self;
    }

    pub fn deinit(self: *GCP) void {
        const a = self.allocator;
        a.free(self.project);
        a.free(self.endpoint);
        a.free(self.token_url);
        a.free(self.client_id);
        a.free(self.client_secret);
        a.free(self.scope);
        a.free(self.access_token_override);
        a.free(self.subscription);
        if (self.token) |t| {
            a.free(t);
        }
        for (self.subscribers.items) |s| {
            a.free(s.topic);
        }
        self.subscribers.deinit();
        a.destroy(self);
    }

    fn ensureToken(self: *GCP) ![]const u8 {
        if (self.access_token_override.len > 0) return self.access_token_override;
        if (self.token) |t| {
            if (utils.nowMonotonic().nanoseconds < self.token_expires_at_ns) return t;
        }
        if (self.client_id.len == 0 or self.client_secret.len == 0) {
            return error.GcpTokenFetchFailed;
        }
        const tok = root.gcp_oauth.fetchToken(
            self.allocator,
            utils.io,
            self.token_url,
            self.client_id,
            self.client_secret,
            self.scope,
        ) catch return error.GcpTokenFetchFailed;
        if (self.token) |old| {
            self.allocator.free(old);
        }
        self.token_expires_at_ns = utils.nowMonotonic().nanoseconds + 3600 * 1_000_000_000 - 30_000_000_000;
        self.token = tok;
        return tok;
    }

    pub fn publish(self: *GCP, subject: []const u8, payload: []const u8) !void {
        const token = try self.ensureToken();
        // subject is the topic name; build the publish URL.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const enc_len = std.base64.standard.Encoder.calcSize(payload.len);
        const enc = try a.alloc(u8, enc_len);
        _ = std.base64.standard.Encoder.encode(enc, payload);

        const url = try std.fmt.allocPrint(a, "{s}/v1/projects/{s}/topics/{s}:publish", .{ self.endpoint, self.project, subject });
        const body = try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"{s}\"}}]}}", .{enc});

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("authorization", try std.fmt.allocPrint(a, "Bearer {s}", .{token}));
        try req.header("content-type", "application/json");
        req.body(body);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.GcpPublishFailed;
    }

    pub fn subscribe(self: *GCP, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
        try self.subscribers.append(.{ .topic = try self.allocator.dupe(u8, subject), .hook = hook });
        if (!self.running.load(.acquire)) {
            self.running.store(true, .release);
            _ = std.Thread.spawn(.{}, run, .{self}) catch {
                self.running.store(false, .release);
                return error.GcpSubscriberSpawnFailed;
            };
        }
    }

    fn run(self: *GCP) void {
        while (self.running.load(.acquire)) {
            self.poll() catch {};
            std.Io.sleep(self.container.?.io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }
    }

    fn poll(self: *GCP) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const token = self.ensureToken() catch return;
        const url = try std.fmt.allocPrint(a, "{s}/v1/projects/{s}/subscriptions/{s}:pull", .{ self.endpoint, self.project, self.subscription });
        const body = "{\"maxMessages\":10,\"returnImmediately\":false}";

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("authorization", try std.fmt.allocPrint(a, "Bearer {s}", .{token}));
        try req.header("content-type", "application/json");
        req.body(body);

        var res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return;
        var sb = try res.allocBody(a, .{ .max_size = 4 * 1024 * 1024 });
        defer sb.deinit();
        const raw = try a.dupe(u8, sb.string());

        const parsed = std.json.parseFromSlice(PullResp, a, raw, .{}) catch return;
        defer parsed.deinit();
        const msgs = parsed.value.receivedMessages orelse return;

        for (msgs) |rm| {
            const dec_len = std.base64.standard.Decoder.calcSizeForSlice(rm.message.data) catch continue;
            const dec = a.alloc(u8, dec_len) catch continue;
            std.base64.standard.Decoder.decode(dec, rm.message.data) catch continue;
            for (self.subscribers.items) |sub| {
                var m = Message{ .context = undefined, .subject = sub.topic, .payload = dec };
                const union_msg: root.pubsubInterface.Message = .{ .gcp = &m };
                dispatch.runHook(self.container.?, sub.hook, union_msg);
            }
            self.acknowledge(token, rm.ackId) catch {};
        }
    }

    fn acknowledge(self: *GCP, token: []const u8, ack_id: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const url = try std.fmt.allocPrint(a, "{s}/v1/projects/{s}/subscriptions/{s}:acknowledge", .{ self.endpoint, self.project, self.subscription });
        const body = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{ack_id});

        var client = zul.http.Client.init(utils.io, a);
        defer client.deinit();
        var req = try client.allocRequest(a, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("authorization", try std.fmt.allocPrint(a, "Bearer {s}", .{token}));
        try req.header("content-type", "application/json");
        req.body(body);
        _ = try req.getResponse(.{});
    }

    const PullResp = struct {
        receivedMessages: ?[]const ReceivedMessage = null,
    };
    const ReceivedMessage = struct {
        ackId: []const u8,
        message: struct { data: []const u8 },
    };

    pub const vtable = root.PubSub.VTable{
        .publish = publishWrap,
        .subscribe = subscribeWrap,
    };
};

fn publishWrap(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
    const self = @as(*GCP, @ptrCast(@alignCast(ptr)));
    return self.publish(subject, payload);
}

fn subscribeWrap(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
    const self = @as(*GCP, @ptrCast(@alignCast(ptr)));
    return self.subscribe(subject, hook);
}
