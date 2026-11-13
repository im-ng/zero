const std = @import("std");

/// Global monotonic count of label-set updates dropped because a capped
/// metric's distinct-label budget was exhausted. Emitted by the metrics writer
/// as the single `otel_metric_overflow` Prometheus series so operators can see
/// when the cap is silently folding series away.
pub var overflow_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn recordOverflow() void {
    _ = overflow_total.fetchAdd(1, .monotonic);
}

/// Current overflow count (label sets dropped due to a cap).
pub fn overflowCount() u64 {
    return overflow_total.load(.monotonic);
}

/// Deterministic hash of a label struct so we can track distinct label sets
/// without storing the labels themselves. Slice fields hash their bytes, so
/// two label sets that render identically collide to the same key.
fn hashLabels(labels: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const ti = @typeInfo(@TypeOf(labels));
    if (ti != .@"struct") {
        @compileError("metric cap labels must be a struct, got: " ++ @typeName(@TypeOf(labels)));
    }
    inline for (ti.@"struct".field_names, ti.@"struct".field_types, ti.@"struct".field_attrs) |f_name, _, _| {
        hashValue(&hasher, @field(labels, f_name));
    }
    return hasher.final();
}

fn hashValue(hasher: *std.hash.Wyhash, v: anytype) void {
    const ti = @typeInfo(@TypeOf(v));
    switch (ti) {
        .int, .float => hasher.update(std.mem.asBytes(&v)),
        .@"enum" => hasher.update(std.mem.asBytes(&@backingInt(v))),
        .pointer => |p| if (p.size == .slice) {
            // Hash the length before the bytes so `{ .a = "ab", .b = "c" }` and
            // `{ .a = "a", .b = "bc" }` don't collide
            hasher.update(std.mem.asBytes(&v.len));
            hasher.update(std.mem.sliceAsBytes(v));
        } else {
            @compileError("metric cap: unsupported label pointer field");
        },
        .optional => if (v) |x| {
            hashValue(hasher, x);
        } else {
            hasher.update(std.mem.asBytes(&[1]u8{0}));
        },
        else => @compileError("metric cap: unsupported label field type: " ++ @typeName(@TypeOf(v))),
    }
}

/// Wraps a labeled metric (counter or histogram) so that, once it has stored
/// `cap` distinct label sets, any further *new* label set is dropped and folded
/// into `overflow_total` instead of being retained. This caps the per-metric
/// label cardinality in memory without touching the vendored metrics library.
fn Cap(comptime Vec: type, comptime is_counter: bool) type {
    return struct {
        vec: Vec,
        seen: std.AutoHashMap(u64, void),
        cap: ?usize,
        alloc: std.mem.Allocator,
        io: std.Io,
        lock: std.Io.RwLock,
        // Last hash that was confirmed present in `seen`, plus a validity flag so
        // a repeated label set (the common fixed-route case) can skip the map and
        // both locks entirely. Guarded by `last_hash_valid`'s acquire/release pair.
        last_hash: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        last_hash_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, io: std.Io, vec: Vec, cap: ?usize) @This() {
            return .{
                .vec = vec,
                .seen = std.AutoHashMap(u64, void).init(alloc),
                .cap = cap,
                .alloc = alloc,
                .io = io,
                .lock = .init,
            };
        }

        // Returns true when this label set is brand new and the cap is already
        // exhausted, meaning the update should be dropped.
        fn gate(self: *@This(), labels: anytype) bool {
            const c = self.cap orelse return false;
            const h = hashLabels(labels);

            // Steady-state fast path: a remembered hash is always present in
            // `seen`, so a match is authoritative. This keeps the per-request
            // metric update free of locks after the first request for a label set.
            if (self.last_hash_valid.load(.acquire) and self.last_hash.load(.monotonic) == h) {
                return false;
            }

            // Known label sets only need the shared (read) lock. The old code took
            // an exclusive lock on every update, which serialized the request path.
            const known = blk: {
                self.lock.lockShared(self.io) catch return false;
                defer self.lock.unlockShared(self.io);
                break :blk self.seen.contains(h);
            };
            if (known) {
                self.remember(h);
                return false;
            }

            self.lock.lock(self.io) catch return false;
            defer self.lock.unlock(self.io);

            // Another thread may have inserted this label set while we waited for
            // the exclusive lock, so re-check before applying the cap.
            if (self.seen.contains(h)) {
                self.remember(h);
                return false;
            }
            if (self.seen.count() >= c) {
                recordOverflow();
                return true;
            }
            // On allocation failure, fail open: emit the metric rather than drop
            // it. The cap is a memory guard, not a correctness gate.
            self.seen.put(h, {}) catch return false;
            self.remember(h);
            return false;
        }

        fn remember(self: *@This(), h: u64) void {
            // Store the hash before publishing `valid`; readers load `valid` with
            // acquire so they never pair a true flag with a stale hash.
            self.last_hash.store(h, .monotonic);
            self.last_hash_valid.store(true, .release);
        }

        pub fn write(self: *@This(), w: *std.Io.Writer) !void {
            try self.vec.write(w);
        }

        pub fn deinit(self: *@This()) void {
            self.vec.deinit();
            self.seen.deinit();
        }

        pub fn incrBy(self: *@This(), labels: anytype, n: anytype) !void {
            if (!is_counter) {
                @compileError("incrBy only valid on a counter wrapper");
            }
            if (self.gate(labels)) return;
            try self.vec.incrBy(labels, n);
        }

        pub fn incr(self: *@This(), labels: anytype) !void {
            if (!is_counter) {
                @compileError("incr only valid on a counter wrapper");
            }
            if (self.gate(labels)) return;
            try self.vec.incr(labels);
        }

        pub fn observe(self: *@This(), labels: anytype, v: anytype) !void {
            if (is_counter) {
                @compileError("observe only valid on a histogram wrapper");
            }
            if (self.gate(labels)) return;
            try self.vec.observe(labels, v);
        }
    };
}

pub fn CapCounter(comptime Vec: type) type {
    return Cap(Vec, true);
}

pub fn CapHistogram(comptime Vec: type) type {
    return Cap(Vec, false);
}

test "hashLabels does not collide across field boundaries" {
    const Labels = struct { a: []const u8, b: []const u8 };
    const x = Labels{ .a = "ab", .b = "c" };
    const y = Labels{ .a = "a", .b = "bc" };
    try std.testing.expect(hashLabels(x) != hashLabels(y));
}

const TestCounter = struct {
    total: u64 = 0,

    pub fn incrBy(self: *TestCounter, _: anytype, n: anytype) !void {
        self.total += @as(u64, @intCast(n));
    }

    pub fn incr(self: *TestCounter, _: anytype) !void {
        self.total += 1;
    }

    pub fn write(self: *TestCounter, w: *std.Io.Writer) !void {
        _ = self;
        _ = w;
    }

    pub fn deinit(self: *TestCounter) void {
        _ = self;
    }
};

test "cap gate drops only new label sets past the limit" {
    const Label = struct { path: []const u8, status: u16 };
    var metric = CapCounter(TestCounter).init(std.testing.allocator, std.testing.io, .{}, 2);
    defer metric.deinit();

    // Fill the cap with two distinct label sets.
    try metric.incrBy(Label{ .path = "/json", .status = 200 }, 1);
    try metric.incrBy(Label{ .path = "/text", .status = 200 }, 1);

    const before = overflowCount();
    // A new set past the cap is dropped and counted.
    try metric.incrBy(Label{ .path = "/new", .status = 200 }, 1);
    try std.testing.expectEqual(before + 1, overflowCount());

    // A known set keeps flowing after the cap is full.
    try metric.incrBy(Label{ .path = "/json", .status = 200 }, 1);
    try std.testing.expectEqual(before + 1, overflowCount());
    try std.testing.expectEqual(@as(u64, 3), metric.vec.total);
}

test "cap gate is a no-op when the cap is disabled" {
    const Label = struct { id: u16 };
    var metric = CapCounter(TestCounter).init(std.testing.allocator, std.testing.io, .{}, null);
    defer metric.deinit();

    const before = overflowCount();
    var i: u16 = 0;
    while (i < 100) : (i += 1) {
        try metric.incrBy(Label{ .id = i }, 1);
    }
    try std.testing.expectEqual(before, overflowCount());
    try std.testing.expectEqual(@as(u64, 100), metric.vec.total);
}
