const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1789570350;

pub fn add_tracker_run(c: *Context) anyerror!void {
    const query =
        \\ -- TODO: write your migration SQL
    ;
    _ = try c.SQL.exec(c, query, .{{}});
}}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .run = add_tracker_run,
};