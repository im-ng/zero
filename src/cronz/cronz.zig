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
    var iterator = std.mem.splitAny(u8, value, ",");
    while (iterator.next()) |item| {
        // global compilation crashes
        var r = try RegExp.compile(self.container.allocator, constants.REGEXP_RANGES);
        const rangeMatches = try RegExp.captures(&r, item);

        if (rangeMatches) |ranges| {
            const _min = try std.fmt.parseInt(u8, ranges.sliceAt(1).?, 10);
            const _max = try std.fmt.parseInt(u8, ranges.sliceAt(2).?, 10);

            if (_min < min and _max > max) {
                return Error.CronError.BadScheduleFormat;
            }

            try self.expandOccurance(map, _max, _min, step);
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
        // global compilation crashes
        var r = try RegExp.compile(self.container.allocator, constants.REGEXP_RANGES);
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
        }
    }

    const step = try std.fmt.parseInt(u8, suffix, 10);

    return self.expandOccurance(map, _max, _min, step);
}

fn expandOccurances(self: *Self, value: []const u8, map: *std.AutoHashMap(u8, bool), max: u8, min: u8) !void {
    // if it *, expand to the limits
    if (std.mem.eql(u8, value, "*")) {
        try self.expandOccurance(map, max, min, 1);
        return;
    }

    //*/5 1-4/5 * * *
    // global compilation crashes
    var s = try RegExp.compile(self.container.allocator, constants.REGEXP_SPLITS);
    const matches = try RegExp.captures(&s, value);
    if (matches) |matched| {
        const prefix = matched.sliceAt(1).?;
        const suffix = matched.sliceAt(2).?;
        return self.expandSteps(prefix, suffix, map, max, min);
    }

    //55-59 1-4/5 * * *
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
            // do nothing
        },
    }

    // expand job occurances
    try self.expandOccurances(minutes, &j.min, totalMinutes, 0);

    try self.expandOccurances(hours, &j.hour, totalHours, 0);

    try self.expandOccurances(days, &j.day, totalDays, 0);

    try self.expandOccurances(months, &j.month, totalMonths, 0);

    try self.expandOccurances(weekDay, &j.dayOfWeek, totalDaysOfWeek, 0);

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
