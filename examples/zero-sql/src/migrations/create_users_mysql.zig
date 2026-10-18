const std = @import("std");
const zero = @import("zero");
const Context = zero.Context;
const migrate = zero.migrate;

pub const migrationNumber: i64 = 1700000005;

pub fn create_users_mysql_run(c: *Context) anyerror!void {
    const query =
        \\ CREATE TABLE IF NOT EXISTS users (
        \\   id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        \\   name VARCHAR(255) NOT NULL,
        \\   email VARCHAR(255) NOT NULL,
        \\   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\ ) ENGINE=InnoDB
    ;
    _ = try c.SQL.exec(c, query, .{});
}

pub const _migrate = &migrate{
    .migrationNumber = migrationNumber,
    .target = .relational,
    .dialect = .mysql,
    .run = create_users_mysql_run,
};
