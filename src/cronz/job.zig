const std = @import("std");
const root = @import("../zero.zig");
const Self = @This();
const Job = @This();

const tick = root.tick;
const DateTime = root.zdt.Datetime;
const container = root.container;
const httpz = root.httpz;
const Context = root.Context;
const utils = root.utils;
const IntContext = root.cronContext;

name: []const u8,
sec: std.AutoHashMap(u8, bool),
min: std.AutoHashMap(u8, bool),
hour: std.AutoHashMap(u8, bool),
day: std.AutoHashMap(u8, bool),
month: std.AutoHashMap(u8, bool),
dayOfWeek: std.AutoHashMap(u8, bool),
exec: *const fn (*root.Context) anyerror!void,

pub fn create(allocator: std.mem.Allocator) !*Job {
    const j = try allocator.create(Job);
    j.sec = std.AutoHashMap(u8, bool).init(allocator);
    j.min = std.AutoHashMap(u8, bool).init(allocator);
    j.hour = std.AutoHashMap(u8, bool).init(allocator);
    j.day = std.AutoHashMap(u8, bool).init(allocator);
    j.month = std.AutoHashMap(u8, bool).init(allocator);
    j.dayOfWeek = std.AutoHashMap(u8, bool).init(allocator);
    return j;
}

pub fn run(self: *Self, context: ?*Context) void {
    if (context == null) {
        return;
    }

    const ctx = context.?;

    var timer = std.time.Timer.start() catch |err| {
        ctx.any(err);
        return;
    };

    self.exec(ctx) catch |err| {
        ctx.any(err);
        return;
    };

    const elapsed: f32 = @floatFromInt(timer.lap() / 1000000);

    const msg = utils.combine(
        ctx.allocator,
        "completed cron job: {s} in {d}ms",
        .{ self.name, elapsed },
    ) catch |err| {
        ctx.any(err);
        return;
    };

    ctx.info(msg);
}

pub fn getTick(_: *Self, now: DateTime) *const tick {
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

pub fn compare(self: *Self, t: DateTime) bool {
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
