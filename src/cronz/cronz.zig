const std = @import("std");
const root = @import("../zero.zig");
const time = std.time;
const arena: type = std.heap.ArenaAllocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const Cronz = @This();
const Self = @This();
const job = root.cronJob.Job;
const dateTime = root.zdt.Datetime;
const Error = root.Error;
const utils = root.utils;
const Context = root.Context;
const httpz = root.httpz;
const regexp = root.regexp;
const RegExp = regexp.Regex;
const constants = root.constants;

const totalSeconds: u8 = 59;
const totalMinutes: u8 = 59;
const totalHours: u8 = 23;
const totalDays: u8 = 31;
const totalMonths: u8 = 12;
const totalDaysOfWeek: u8 = 6;
const secondsIncluded: u8 = 6;
const minutesIncluded: u8 = 5;

const _req: *httpz.Request = undefined;
const _res: *httpz.Response = undefined;

/// Set by cronz before calling a job's exec callback. Read-only for consumers.
pub var current_job_name: ?[]const u8 = null;

ticker: time.Timer = undefined,
thread: std.Thread = undefined,
container: *root.container = undefined,
jobs: std.array_list.Managed(job) = undefined,
mu: std.Thread.Mutex = undefined,
running: Atomic(bool) = undefined,
request: *httpz.Request = undefined,
response: *httpz.Response = undefined,

pub fn create(container: *root.container) !*Cronz {
    const c = try container.allocator.create(Cronz);
    errdefer container.allocator.destroy(c);

    c.mu = .{};
    c.running = Atomic(bool).init(true);
    c.container = container;
    c.ticker = try time.Timer.start();
    c.jobs = std.array_list.Managed(job).init(container.allocator);
    c.thread = try Thread.spawn(.{}, Cronz.runSchedules, .{ c, std.time.nanoTimestamp() });

    return c;
}

pub fn destroy(self: *Self) void {
    self.running.store(false, .release);
    self.thread.join();
}

fn prepareChildAllocator(self: *Self) !*arena {
    const ca: *arena = try self.container.allocator.create(arena);
    errdefer self.container.allocator.destroy(ca);

    ca.* = arena.init(self.container.allocator);
    errdefer ca.deinit();

    return ca;
}

fn destroryChildAllocator(self: *Self, ca: *arena) void {
    const caPtr: *arena = @ptrCast(@alignCast(ca.allocator().ptr));
    caPtr.deinit();

    self.container.allocator.destroy(caPtr);
}

pub fn runSchedules(self: *Self, _: i128) void {
    while (self.running.load(.monotonic)) {
        std.Thread.sleep(std.time.ns_per_s);
        const now = dateTime.nowUTC();
        for (self.jobs.items) |j| {
            if (j.compare(now)) {
                const ca = self.prepareChildAllocator() catch |err| {
                    self.container.log.any(err);
                    continue;
                };
                defer self.destroryChildAllocator(ca);

                var ctx = try Context.init(
                    ca.allocator(),
                    self.container,
                    self.request,
                    self.response,
                );

                const thread = Thread.spawn(
                    .{},
                    job.run,
                    .{ j, &ctx },
                ) catch |err| {
                    self.container.log.any(err);
                    return;
                };

                thread.join();
            }
        }
    }
}

fn expandOccurance(
    _: *Self,
    map: *std.AutoHashMap(u8, bool),
    max: u8,
    min: u8,
    step: u8,
) !void {
    var i = min;
    while (i <= max) {
        try map.put(i, true);
        i += step;
    }
}

fn expandRanges(
    self: *Self,
    value: []const u8,
    map: *std.AutoHashMap(u8, bool),
    max: u8,
    min: u8,
    step: u8,
) !void {
    var r = try RegExp.compile(self.container.allocator, constants.REGEXP_RANGES);
    defer r.deinit();

    var iterator = std.mem.splitAny(u8, value, ",");
    while (iterator.next()) |item| {
        const rangeMatches = try RegExp.captures(&r, item);

        if (rangeMatches) |ranges| {
            const _min = try std.fmt.parseInt(u8, ranges.sliceAt(1).?, 10);
            const _max = try std.fmt.parseInt(u8, ranges.sliceAt(2).?, 10);

            if (_min < min and _max > max) {
                return Error.CronError.BadScheduleFormat;
            }

            try self.expandOccurance(map, _max, _min, step);
            var mut_ranges = ranges;
            mut_ranges.deinit();
        } else {
            const _item = try std.fmt.parseInt(u8, item, 10);
            if (_item < min and _item > max) {
                return Error.CronError.BadScheduleFormat;
            }

            try map.put(_item, true);
        }
    }

    return;
}

fn expandSteps(
    self: *Self,
    prefix: []const u8,
    suffix: []const u8,
    map: *std.AutoHashMap(u8, bool),
    max: u8,
    min: u8,
) !void {
    var _min = min;
    var _max = max;

    if (std.mem.eql(u8, prefix, " ") == false and
        std.mem.eql(u8, prefix, "*") == false)
    {
        var r = try RegExp.compile(self.container.allocator, constants.REGEXP_RANGES);
        defer r.deinit();
        const rangeMatches = try RegExp.captures(&r, suffix);
        if (rangeMatches == null) {
            return Error.CronError.BadScheduleFormat;
        }
        if (rangeMatches) |ranges| {
            _min = try std.fmt.parseInt(u8, ranges.sliceAt(1).?, 10);
            _max = try std.fmt.parseInt(u8, ranges.sliceAt(2).?, 10);

            if (_min < min and _max > max) {
                return Error.CronError.BadScheduleFormat;
            }
            var mut_ranges = ranges;
            mut_ranges.deinit();
        }
    }

    const step = try std.fmt.parseInt(u8, suffix, 10);

    return self.expandOccurance(map, _max, _min, step);
}

fn expandOccurances(self: *Self, value: []const u8, map: *std.AutoHashMap(u8, bool), max: u8, min: u8) !void {
    if (value.len == 0) return;

    // if it *, expand to the limits
    if (std.mem.eql(u8, value, "*")) {
        try self.expandOccurance(map, max, min, 1);
        return;
    }

    var s = try RegExp.compile(self.container.allocator, constants.REGEXP_SPLITS);
    defer s.deinit();
    const matches = try RegExp.captures(&s, value);
    if (matches) |matched| {
        const prefix = matched.sliceAt(1).?;
        const suffix = matched.sliceAt(2).?;
        var mut_matched = matched;
        mut_matched.deinit();
        return self.expandSteps(prefix, suffix, map, max, min);
    }

    return self.expandRanges(value, map, max, min, 1);
}

fn parseSchedule(self: *Self, schedule: []const u8) !job {
    var seconds: []const u8 = "";
    var minutes: []const u8 = "";
    var hours: []const u8 = "";
    var days: []const u8 = "";
    var months: []const u8 = "";
    var weekDay: []const u8 = "";
    var iterator = std.mem.splitAny(u8, schedule, " ");

    var scheduleLength: usize = 0;
    while (iterator.next()) |part| {
        switch (scheduleLength) {
            0 => seconds = part,
            1 => minutes = part,
            2 => hours = part,
            3 => days = part,
            4 => months = part,
            5 => weekDay = part,
            else => {},
        }
        scheduleLength += 1;
    }

    switch (scheduleLength) {
        5...6 => {
            // do nothing
        },
        else => {
            return Error.CronError.BadScheduleFormat;
        },
    }

    // create job for execution
    var j = try job.create(self.container.allocator);

    var index: u8 = 0;
    switch (scheduleLength) {
        6 => {
            try self.expandOccurances(seconds, &j.sec, totalSeconds, 0);
            index += 1;
        },
        else => {
            // Legacy 5-field: seconds field was never set, match every second
            try self.expandOccurance(&j.sec, totalSeconds, 0, 1);
        },
    }

    // expand job occurances
    try self.expandOccurances(minutes, &j.min, totalMinutes, 0);

    try self.expandOccurances(hours, &j.hour, totalHours, 0);

    try self.expandOccurances(days, &j.day, totalDays, 0);

    try self.expandOccurances(months, &j.month, totalMonths, 0);

    try self.expandOccurances(weekDay, &j.dayOfWeek, totalDaysOfWeek, 0);

    // Safety: if dayOfWeek is empty (legacy 5-field), match every day
    if (j.dayOfWeek.count() == 0) {
        try self.expandOccurance(&j.dayOfWeek, totalDaysOfWeek, 0, 1);
    }

    return j;
}

pub fn addCron(self: *Self, schedule: []const u8, name: []const u8, hook: *const fn (*root.Context) anyerror!void) !void {
    var j = self.parseSchedule(schedule) catch |err| {
        self.container.log.any(err);
        return;
    };

    j.name = name;
    j.exec = hook;

    self.mu.lock();
    try self.jobs.append(j);
    self.mu.unlock();

    const msg = utils.combine(
        self.container.allocator,
        "{s} {s} cron job added for execution",
        .{ j.name.?, schedule },
    ) catch |err| {
        self.container.log.any(err);
        return;
    };

    self.container.log.info(msg);
}

test "expandOccurance fills range with step 1" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();
    var c = Cronz{ .container = undefined };
    try c.expandOccurance(&map, 59, 0, 1);
    try std.testing.expect(map.count() == 60);
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(59));
}

test "expandOccurance fills range with step 5" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();
    var c = Cronz{ .container = undefined };
    try c.expandOccurance(&map, 59, 0, 5);
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(5));
    try std.testing.expect(map.contains(55));
    try std.testing.expect(!map.contains(3));
}

test "expandOccurance fills limited range" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();
    var c = Cronz{ .container = undefined };
    try c.expandOccurance(&map, 23, 0, 1);
    try std.testing.expect(map.count() == 24);
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(23));
    try std.testing.expect(!map.contains(24));
}

test "expandOccurance fills minutes range" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();
    var c = Cronz{ .container = undefined };
    try c.expandOccurance(&map, 59, 0, 1);
    try std.testing.expect(map.count() == 60);
}

test "parseSchedule rejects invalid schedule format" {
    const allocator = std.testing.allocator;
    var map_jobs = std.array_list.Managed(job).init(allocator);
    defer map_jobs.deinit();

    var c = Cronz{
        .container = undefined,
        .jobs = map_jobs,
    };
    const result = c.parseSchedule("* * *");
    try std.testing.expectError(Error.CronError.BadScheduleFormat, result);
}

test "parseSchedule rejects empty schedule" {
    const allocator = std.testing.allocator;
    var map_jobs = std.array_list.Managed(job).init(allocator);
    defer map_jobs.deinit();

    var c = Cronz{
        .container = undefined,
        .jobs = map_jobs,
    };
    const result = c.parseSchedule("");
    try std.testing.expectError(Error.CronError.BadScheduleFormat, result);
}

test "parseSchedule rejects too-long schedule" {
    const allocator = std.testing.allocator;
    var map_jobs = std.array_list.Managed(job).init(allocator);
    defer map_jobs.deinit();

    var c = Cronz{
        .container = undefined,
        .jobs = map_jobs,
    };
    const result = c.parseSchedule("* * * * * * *");
    try std.testing.expectError(Error.CronError.BadScheduleFormat, result);
}

fn mockContainer(allocator: std.mem.Allocator) root.container {
    return root.container{
        .allocator = allocator,
        .appName = undefined,
        .appVersion = undefined,
        .log = undefined,
        .config = undefined,
        .metricz = undefined,
        .authProvider = undefined,
        .redis = undefined,
        .rdz = undefined,
        .SQL = undefined,
        .services = undefined,
        .pubsub = null,
        .Kakfa = null,
    };
}

test "expandRanges parses comma-separated values" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandRanges("10,20,30", &map, 59, 0, 1);
    try std.testing.expectEqual(@as(usize, 3), map.count());
    try std.testing.expect(map.contains(10));
    try std.testing.expect(map.contains(20));
    try std.testing.expect(map.contains(30));
}

test "expandRanges parses range expression" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandRanges("10-15", &map, 59, 0, 1);
    try std.testing.expectEqual(@as(usize, 6), map.count());
    try std.testing.expect(map.contains(10));
    try std.testing.expect(map.contains(15));
    try std.testing.expect(!map.contains(9));
    try std.testing.expect(!map.contains(16));
}

test "expandSteps parses step expression" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandSteps("*", "15", &map, 59, 0);
    try std.testing.expectEqual(@as(usize, 4), map.count());
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(15));
    try std.testing.expect(map.contains(30));
    try std.testing.expect(map.contains(45));
}

test "expandSteps parses range-with-step expression" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandSteps("*", "3", &map, 10, 0);
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(3));
    try std.testing.expect(map.contains(6));
    try std.testing.expect(map.contains(9));
}

test "expandOccurances dispatches wildcard" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandOccurances("*", &map, 59, 0);
    try std.testing.expectEqual(@as(usize, 60), map.count());
}

test "expandOccurances dispatches step expression" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandOccurances("*/10", &map, 59, 0);
    try std.testing.expect(map.contains(0));
    try std.testing.expect(map.contains(10));
    try std.testing.expect(map.contains(20));
    try std.testing.expect(map.contains(30));
    try std.testing.expect(map.contains(40));
    try std.testing.expect(map.contains(50));
}

test "expandOccurances dispatches range expression" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u8, bool).init(allocator);
    defer map.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{ .container = &mc };

    try c.expandOccurances("5-10", &map, 59, 0);
    try std.testing.expectEqual(@as(usize, 6), map.count());
    try std.testing.expect(map.contains(5));
    try std.testing.expect(map.contains(10));
}

test "parseSchedule accepts valid 5-field schedule" {
    const allocator = std.testing.allocator;
    var map_jobs = std.array_list.Managed(job).init(allocator);
    defer map_jobs.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{
        .container = &mc,
        .jobs = map_jobs,
    };

    var j = try c.parseSchedule("* * * * *");
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }
    try std.testing.expectEqual(@as(usize, 60), j.min.count());
    try std.testing.expectEqual(@as(usize, 24), j.hour.count());
    try std.testing.expectEqual(@as(usize, 32), j.day.count());
    try std.testing.expectEqual(@as(usize, 13), j.month.count());
    try std.testing.expectEqual(@as(usize, 0), j.dayOfWeek.count());
}

test "parseSchedule accepts valid 6-field schedule with seconds" {
    const allocator = std.testing.allocator;
    var map_jobs = std.array_list.Managed(job).init(allocator);
    defer map_jobs.deinit();

    var mc = mockContainer(allocator);
    var c = Cronz{
        .container = &mc,
        .jobs = map_jobs,
    };

    var j = try c.parseSchedule("30 * * * * *");
    defer {
        j.sec.deinit();
        j.min.deinit();
        j.hour.deinit();
        j.day.deinit();
        j.month.deinit();
        j.dayOfWeek.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), j.sec.count());
    try std.testing.expect(j.sec.contains(30));
    try std.testing.expectEqual(@as(usize, 60), j.min.count());
}
