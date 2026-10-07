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
    inline for (ti.@"struct".fields) |f| {
        hashValue(&hasher, @field(labels, f.name));
    }
    return hasher.final();
}

fn hashValue(hasher: *std.hash.Wyhash, v: anytype) void {
    const ti = @typeInfo(@TypeOf(v));
    switch (ti) {
        .int, .float => hasher.update(std.mem.asBytes(&v)),
        .@"enum" => hasher.update(std.mem.asBytes(&@intFromEnum(v))),
        .pointer => |p| if (p.size == .slice) {
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
        lock: std.Io.Mutex,

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
            if (self.cap) |c| {
                const h = hashLabels(labels);
                self.lock.lock(self.io) catch {};
                defer self.lock.unlock(self.io);
                if (self.seen.contains(h)) return false;
                if (self.seen.count() >= c) {
                    recordOverflow();
                    return true;
                }
                self.seen.put(h, {}) catch {};
            }
            return false;
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
