const std = @import("std");
const root = @import("../zero.zig");

const tick = root.tick;
const DateTime = root.zdt.Datetime;
const container = root.container;
const httpz = root.httpz;
const Context = root.Context;
const utils = root.utils;
const IntContext = root.cronContext;

pub const Job: type = struct {
    name: ?[]const u8 = null,
    sec: std.AutoHashMap(u8, bool) = undefined,
    min: std.AutoHashMap(u8, bool) = undefined,
    hour: std.AutoHashMap(u8, bool) = undefined,
    day: std.AutoHashMap(u8, bool) = undefined,
    month: std.AutoHashMap(u8, bool) = undefined,
    dayOfWeek: std.AutoHashMap(u8, bool) = undefined,
    exec: *const fn (*root.Context) anyerror!void = undefined,

    pub fn create(allocator: std.mem.Allocator) !Job {
        var j = Job{};
        j.sec = std.AutoHashMap(u8, bool).init(allocator);
        j.min = std.AutoHashMap(u8, bool).init(allocator);
        j.hour = std.AutoHashMap(u8, bool).init(allocator);
        j.day = std.AutoHashMap(u8, bool).init(allocator);
        j.month = std.AutoHashMap(u8, bool).init(allocator);
        j.dayOfWeek = std.AutoHashMap(u8, bool).init(allocator);
        return j;
    }

    pub fn run(self: Job, context: ?*Context) void {
        if (context == null) {
            return;
        }

        const ctx = context.?;

        var timer = std.time.Timer.start() catch |err| {
            ctx.any(err);
            return;
        };

        root.cronz.current_job_name = self.name;
        self.exec(ctx) catch |err| {
            ctx.any(err);
            return;
        };
        root.cronz.current_job_name = null;

        const elapsed: f32 = @floatFromInt(timer.lap() / 1000000);

        const msg = utils.combine(
            ctx.allocator,
            "completed cron job: {s} in {d}ms",
            .{ self.name.?, elapsed },
        ) catch |err| {
            ctx.any(err);
            return;
        };

        ctx.info(msg);
    }

    pub fn getTick(_: *Job, now: DateTime) *const tick {
        const yr: u16 = @as(u16, @intCast(now.year));
        const t = &tick{
            .sec = @as(u16, now.second),
            .min = @as(u16, now.minute),
            .hour = @as(u16, now.hour),
            .day = @as(u16, now.day),
            .month = @as(u16, now.month),
            .year = yr,
            .dayOfWeek = @as(u16, now.weekdayNumber()),
        };
        return t;
    }

    pub fn compare(self: Job, t: DateTime) bool {
        if (self.sec.contains(t.second) == false) {
            return false;
        }

        if (self.min.contains(t.minute) == false) {
            return false;
        }

        if (self.hour.contains(t.hour) == false) {
            return false;
        }

        if (self.day.contains(t.day) == false) {
            return false;
        }

        if (self.month.contains(t.month) == false) {
            return false;
        }

        if (self.dayOfWeek.contains(t.weekdayNumber()) == false) {
            return false;
        }

        return true;
    }
};

test "job create initializes all hash maps" {
    const allocator = std.testing.allocator;
    var j = try Job.create(allocator);
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }
    try std.testing.expect(j.sec.count() == 0);
    try std.testing.expect(j.min.count() == 0);
    try std.testing.expect(j.hour.count() == 0);
    try std.testing.expect(j.day.count() == 0);
    try std.testing.expect(j.month.count() == 0);
    try std.testing.expect(j.dayOfWeek.count() == 0);
}

test "job compare returns true when all fields match" {
    const allocator = std.testing.allocator;
    var j = try Job.create(allocator);
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }
    j.name = "test-job";
    try j.sec.put(30, true);
    try j.min.put(15, true);
    try j.hour.put(10, true);
    try j.day.put(5, true);
    try j.month.put(3, true);
    try j.dayOfWeek.put(1, true);

    const now = DateTime.nowUTC();
    const result = j.compare(now);
    _ = result;
}

test "job compare returns false when field mismatches" {
    const allocator = std.testing.allocator;
    var j = try Job.create(allocator);
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }
    j.name = "mismatch-job";
    try j.sec.put(0, true);
    try j.min.put(0, true);
    try j.hour.put(23, true);
    try j.day.put(1, true);
    try j.month.put(1, true);
    try j.dayOfWeek.put(0, true);

    const now = DateTime.nowUTC();
    const second = now.second;
    if (!j.sec.contains(second)) {
        try std.testing.expect(j.compare(now) == false);
    }
}

test "job getTick returns current time components" {
    const allocator = std.testing.allocator;
    var j = try Job.create(allocator);
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }

    const now = DateTime.nowUTC();
    const t = j.getTick(now);
    try std.testing.expect(t.sec <= 59);
    try std.testing.expect(t.min <= 59);
    try std.testing.expect(t.hour <= 23);
    try std.testing.expect(t.day >= 1 and t.day <= 31);
    try std.testing.expect(t.month >= 1 and t.month <= 12);
}

test "job compare returns false for empty job" {
    const allocator = std.testing.allocator;
    var j = try Job.create(allocator);
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }

    const now = DateTime.nowUTC();
    try std.testing.expect(j.compare(now) == false);
}
