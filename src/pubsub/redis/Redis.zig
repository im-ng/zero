const std = @import("std");
const root = @import("../../zero.zig");
const constants = root.constants;
pub const Redis = @This();
const Self = @This();

const Context = root.Context;
const utils = root.utils;
const httpz = root.httpz;
const arena_t = std.heap.ArenaAllocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const Subscriber = struct {
    topic: []const u8,
    exec: *const fn (*root.Context) anyerror!void,
};

allocator: std.mem.Allocator = undefined,
container: *root.container = undefined,

// request/response connection (used for PUBLISH)
stream: ?std.Io.net.Stream = null,
reader: ?std.Io.Reader = undefined,
writer: ?std.Io.Writer = undefined,

// dedicated push connection (used for SUBSCRIBE)
sub_stream: ?std.Io.net.Stream = null,
sub_reader: ?std.Io.Reader = undefined,
sub_writer: ?std.Io.Writer = undefined,

rdbuf: [8192]u8 = undefined,
wbuf: [8192]u8 = undefined,
sub_rdbuf: [8192]u8 = undefined,
sub_wbuf: [8192]u8 = undefined,

    subscriber: std.array_list.Managed(Subscriber) = undefined,
    mu: std.Io.Mutex = undefined,
    signal: Atomic(bool) = undefined,
    thread: std.Thread = undefined,
    started: bool = false,
    isPubSubSet: bool = false,
    // Connection parameters retained so the consumer can reconnect on drop.
    host: []const u8 = undefined,
    port: u16 = 0,
    user: []const u8 = undefined,
    password: []const u8 = undefined,
    db: u16 = 0,

pub fn create(
    container: *root.container,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    db: u16,
) !*Redis {
    const self = try container.allocator.create(Redis);
    errdefer container.allocator.destroy(self);

    self.* = .{
        .allocator = container.allocator,
        .container = container,
        .subscriber = std.array_list.Managed(Subscriber).init(container.allocator),
    };
    self.mu = .init;
    self.signal = Atomic(bool).init(true);

    // Retain connection parameters so the consumer can reconnect after a drop.
    self.host = host;
    self.port = port;
    self.user = user;
    self.password = password;
    self.db = db;

    try self.connect();

    return self;
}

/// Establish (or re-establish) the request/response and push connections,
/// authenticate, and select the target DB. Closes any prior sockets first.
fn connect(self: *Self) !void {
    self.disconnect();

    const addr = try std.Io.net.IpAddress.parseIp4(self.host, self.port);

    const conn = try addr.connect(self.container.io, .{ .mode = .stream });
    self.stream = conn;
    self.reader = conn.reader(self.container.io, &self.rdbuf).interface;
    self.writer = conn.writer(self.container.io, &self.wbuf).interface;

    const sconn = try addr.connect(self.container.io, .{ .mode = .stream });
    self.sub_stream = sconn;
    self.sub_reader = sconn.reader(self.container.io, &self.sub_rdbuf).interface;
    self.sub_writer = sconn.writer(self.container.io, &self.sub_wbuf).interface;

    if (self.password.len > 0) {
        if (self.user.len > 0) {
            try execCommand(&self.writer.?, &.{ "AUTH", self.user, self.password });
        } else {
            try execCommand(&self.writer.?, &.{ "AUTH", self.password });
        }
        _ = try takeLine(&self.reader.?, self.allocator);
    }

    if (self.db > 0) {
        var db_buf: [8]u8 = undefined;
        const db_str = try std.fmt.bufPrint(&db_buf, "{d}", .{self.db});
        try execCommand(&self.writer.?, &.{ "SELECT", db_str });
        _ = try takeLine(&self.reader.?, self.allocator);
    }

    self.isPubSubSet = true;
}

/// Close the active sockets (best-effort). Safe to call when not connected.
fn disconnect(self: *Self) void {
    if (self.stream) |s| s.close(self.container.io);
    if (self.sub_stream) |s| s.close(self.container.io);
    self.stream = null;
    self.sub_stream = null;
    self.reader = null;
    self.writer = null;
    self.sub_reader = null;
    self.sub_writer = null;
}

/// Re-issue SUBSCRIBE for every registered topic on the (re)connected push socket.
fn resubscribe(self: *Self) void {
    for (self.subscriber.items) |sub| {
        var w = self.sub_writer orelse break;
        encodeCommand(&w, &.{ "SUBSCRIBE", sub.topic }) catch continue;
        if (readSubFrame(&self.sub_reader.?, self.allocator) catch null) |frame| {
            freeFrame(frame, self.allocator);
        }
    }
}

pub fn destroy(self: *Self) void {
    self.signal.store(false, .release);
    if (self.subscriber.items.len > 0) {
        self.thread.join();
    }
    if (self.stream) |s| s.close(self.container.io);
    if (self.sub_stream) |s| s.close(self.container.io);
}

pub fn Publish(self: *Self, subject: []const u8, payload: []const u8) !void {
    var w = self.writer.?;
    try encodeCommand(&w, &.{ "PUBLISH", subject, payload });
    const reply = (try takeLine(&self.reader.?, self.allocator)) orelse return error.RedisPublishFailed;
    defer self.allocator.free(reply);
    if (reply.len > 0 and reply[0] == '-') {
        self.container.log.info(reply);
        return error.RedisPublishFailed;
    }
}

pub fn addSubscriber(self: *Self, topic: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    self.mu.lock(self.container.io) catch {};
    try self.subscriber.append(.{ .topic = topic, .exec = hook });
    self.mu.unlock(self.container.io);

    var w = self.sub_writer.?;
    try encodeCommand(&w, &.{ "SUBSCRIBE", topic });
    // consume the initial "subscribe" confirmation frame
    if (try readSubFrame(&self.sub_reader.?, self.allocator)) |frame| {
        freeFrame(frame, self.allocator);
    }

    const msg = utils.combine(self.allocator, "topic:{s} redis subscriber added", .{topic}) catch return;
    self.container.log.info(msg);
}

pub fn startSubscription(self: *Self) !void {
    if (self.started) return;
    if (self.subscriber.items.len == 0) return;
    self.thread = Thread.spawn(.{}, Self.subscriptions, .{self}) catch |err| {
        self.container.log.Any(self.allocator, err);
        return;
    };
    self.started = true;
}

fn subscriptions(self: *Self) !void {
    while (self.signal.load(.monotonic)) {
        self.consume() catch |err| {
            self.container.log.Any(self.allocator, err);
            // Connection dropped: tear down, reconnect, and re-subscribe, then
            // resume. This keeps the subscription alive across Redis restarts /
            // network blips instead of the consumer thread dying permanently.
            self.disconnect();
            self.connect() catch |e| {
                self.container.log.Any(self.allocator, e);
                std.Io.sleep(self.container.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
                continue;
            };
            self.resubscribe();
            std.Io.sleep(self.container.io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
            continue;
        };
        break;
    }
}

fn consume(self: *Self) !void {
    while (self.signal.load(.monotonic)) {
        const frame = try readSubFrame(&self.sub_reader.?, self.allocator) orelse continue;
        if (std.mem.eql(u8, frame.kind, "message") and frame.elements.len >= 3) {
            self.dispatch(frame.elements[1], frame.elements[2]);
        }
        freeFrame(frame, self.allocator);
    }
}

fn dispatch(self: *Self, channel: []const u8, payload: []const u8) void {
    for (self.subscriber.items) |sub| {
        if (std.mem.eql(u8, sub.topic, channel)) {
            self.runHook(sub.exec, channel, payload);
        }
    }
}

fn runHook(self: *Self, hook: *const fn (*root.Context) anyerror!void, channel: []const u8, payload: []const u8) void {
    const ca = self.allocator.create(arena_t) catch return;
    ca.* = arena_t.init(self.allocator);
    errdefer {
        ca.deinit();
        self.allocator.destroy(ca);
    }

    var ctx = Context.init(ca.allocator(), self.container, @as(*httpz.Request, undefined), @as(*httpz.Response, undefined)) catch return;
    const context = &ctx;

    var message = root.redisMessage{
        .context = context,
        .subject = channel,
        .payload = payload,
    };
    context.message = .{ .redis = &message };

    // Retry the handler a few times; on a poison message, dead-letter it to
    // `<channel>.dlq`.
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
            const dlq = std.fmt.allocPrint(self.allocator, "{s}.dlq", .{channel}) catch break;
            defer self.allocator.free(dlq);
            self.container.metricz.dlq(.{ .topic = channel, .consumer = "dlq" }) catch {};
            self.Publish(dlq, payload) catch |dlerr| self.container.log.Any(self.allocator, dlerr);
            break;
        };
        break;
    }
}

// ---- RESP helpers ----

fn encodeCommand(w: *std.Io.Writer, args: []const []const u8) !void {
    try w.print("*{d}\r\n", .{args.len});
    for (args) |a| {
        try w.print("${d}\r\n{s}\r\n", .{a.len, a});
    }
}

fn execCommand(w: *std.Io.Writer, args: []const []const u8) !void {
    try encodeCommand(w, args);
}

/// Reads a push frame from a subscribe connection. Returns null on stream end.
fn readSubFrame(r: *std.Io.Reader, alloc: std.mem.Allocator) !?Frame {
    const first = try takeLine(r, alloc) orelse return null;
    if (first.len == 0 or first[0] != '*') {
        alloc.free(first);
        return null;
    }
    const count = std.fmt.parseInt(usize, first[1..], 10) catch {
        alloc.free(first);
        return null;
    };
    alloc.free(first);

    const elements = try alloc.alloc([]u8, count);
    errdefer alloc.free(elements);
    for (elements) |*e| e.* = &.{};

    var kind: []u8 = &.{};
    for (elements, 0..) |*e, i| {
        const line = try takeLine(r, alloc) orelse return null;
        if (line.len > 0 and line[0] == '$') {
            const len = std.fmt.parseInt(usize, line[1..], 10) catch {
                alloc.free(line);
                return null;
            };
            alloc.free(line);
            e.* = try r.readAlloc(alloc, len);
            _ = try r.takeDelimiterInclusive('\n');
        } else {
            // integer or simple-string element (e.g. confirmations)
            e.* = line;
        }
        if (i == 0) kind = e.*;
    }

    return Frame{ .kind = kind, .elements = elements };
}

fn freeFrame(frame: Frame, alloc: std.mem.Allocator) void {
    for (frame.elements) |e| alloc.free(e);
    alloc.free(frame.elements);
    // frame.kind aliases elements[0]; already freed above.
}

/// Reads up to and including '\n', trims CR/LF, returns an owned copy (null on EOF).
fn takeLine(r: *std.Io.Reader, alloc: std.mem.Allocator) !?[]u8 {
    const slice = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, slice, "\r\n");
    return try alloc.dupe(u8, trimmed);
}

const Frame = struct {
    kind: []u8,
    elements: [][]u8,
};

/// Type-erased VTable conforming to `pubsubInterface.Interface.VTable`.
pub const vtable = root.pubsubInterface.Interface.VTable{
    .publish = struct {
        fn call(ptr: *anyopaque, subject: []const u8, payload: []const u8) anyerror!void {
            const self: *Redis = @ptrCast(@alignCast(ptr));
            try self.Publish(subject, payload);
        }
    }.call,
    .subscribe = struct {
        fn call(ptr: *anyopaque, subject: []const u8, hook: *const fn (*root.Context) anyerror!void) anyerror!void {
            const self: *Redis = @ptrCast(@alignCast(ptr));
            try self.addSubscriber(subject, hook);
        }
    }.call,
};

fn writtenLen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) : (i += 1) {}
    return i;
}

// ===================== Tests =====================


test "redis readSubFrame parses a message push frame" {
    const payload = "*3\r\n$7\r\nmessage\r\n$5\r\nusers\r\n$11\r\nhello world\r\n";
    var r = std.Io.Reader.fixed(payload);
    const frame = (try readSubFrame(&r, std.testing.allocator)) orelse return error.TestUnexpectedResult;
    defer freeFrame(frame, std.testing.allocator);
    try std.testing.expectEqualStrings("message", frame.kind);
    try std.testing.expectEqualStrings("users", frame.elements[1]);
    try std.testing.expectEqualStrings("hello world", frame.elements[2]);
}

test "redis readSubFrame returns null on EOF" {
    var r = std.Io.Reader.fixed("");
    try std.testing.expect((try readSubFrame(&r, std.testing.allocator)) == null);
}

test "redis encodeCommand emits a valid RESP frame" {
    var buf: [128]u8 = std.mem.zeroes([128]u8);
    var w = std.Io.Writer.fixed(&buf);
    try encodeCommand(&w, &.{ "PUBLISH", "users", "hi" });
    // count the bytes written by re-reading what the fixed writer holds
    const written = writtenLen(&buf);
    const expected = "*3\r\n$7\r\nPUBLISH\r\n$5\r\nusers\r\n$2\r\nhi\r\n";
    try std.testing.expectEqualStrings(expected, buf[0..written]);
}
