const std = @import("std");
const root = @import("../zero.zig");

const Context = root.Context;
const container = root.container;
const migration = root.migration;
const migrate = root.migrate;
const utils = root.utils;
const dateTime = root.zdt.Datetime;

const migrationTable =
    \\ CREATE TABLE IF NOT EXISTS zero_migrations (
    \\ epoch BIGINT NOT NULL,
    \\ execution VARCHAR(4) NOT NULL ,
    \\ start_time VARCHAR(100) NOT NULL,
    \\ duration BIGINT,
    \\ constraint primary_key primary key (epoch, execution)
    \\ );
;

const lastMigrationRecord = "SELECT COALESCE(MAX(epoch), 0) FROM zero_migrations;";

const insertMigrationRecord = "INSERT INTO zero_migrations (epoch, execution, start_time, duration) VALUES ($1, $2, $3, $4);";

pub fn checkAndCreateMigrationTable(ctx: *Context) !void {
    const dialect = ctx.container.config.get("DB_DIALECT");
    if (std.mem.eql(u8, "postgres", dialect)) {
        const id = try ctx.SQL.exec(migrationTable, .{});
        if (id) |_| {
            ctx.info("migration table created");
        }
    } else if (std.mem.eql(u8, "sqlite", dialect)) {
        ctx.SQLite.exec(migrationTable, .{}) catch |err| {
            var buffer: []u8 = undefined;
            buffer = try ctx.allocator.alloc(u8, 100);
            buffer = try std.fmt.bufPrint(buffer, "migration table creation failed: {}", .{err});
            return;
        };
        ctx.info("migration table created");
    }
}

pub fn lastMigration(ctx: *Context) !i64 {
    const dialect = ctx.container.config.get("DB_DIALECT");
    if (std.mem.eql(u8, "postgres", dialect)) {
        const result = try ctx.SQL.queryRow(lastMigrationRecord, .{});
        if (result) |r| {
            return r.get(i64, 0);
        }
    } else if (std.mem.eql(u8, "sqlite", dialect)) {
        const result = try ctx.SQLite.queryRow(i64, lastMigrationRecord, .{});
        if (result) |r| {
            return r;
        }
    }

    return 0;
}

pub fn insertMigration(ctx: *Context, m: *const migrate, duration: u64) !?i64 {
    const dialect = ctx.container.config.get("DB_DIALECT");
    if (std.mem.eql(u8, "postgres", dialect)) {
        const epoch = m.migrationNumber;
        const status = "UP";
        const startTime = try utils.sqlTimestampz(ctx.allocator);

        const id = try ctx.SQL.exec(insertMigrationRecord, .{ epoch, status, startTime, duration });

        if (id) |_| {
            return id;
        }
    } else if (std.mem.eql(u8, "sqlite", dialect)) {
        const epoch = m.migrationNumber;
        const status = "UP";
        const startTime = try utils.sqlTimestampz(ctx.allocator);

        ctx.SQLite.exec(insertMigrationRecord, .{ epoch, status, startTime, duration }) catch |err| {
            var buffer: []u8 = undefined;
            buffer = try ctx.allocator.alloc(u8, 100);
            buffer = try std.fmt.bufPrint(buffer, "migration table creation failed: {}", .{err});
            return 0;
        };

        const result = try ctx.SQLite.queryRow(i64, lastMigrationRecord, .{});
        if (result) |r| {
            return r;
        }
    }

    return 0;
}

// pub fn commitExecution(c: *container) !void {}

// pub fn rollbackExecution(c: *container) !void {}
