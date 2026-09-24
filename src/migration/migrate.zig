const std = @import("std");
const migrate = @This();
const Self = @This();

const root = @import("../zero.zig");
const util = root.utils;

/// Which datasource a migration applies to. `.relational` runs through the
/// active `ctx.SQL` (postgres/sqlite/duckdb/clickhouse); `.nosql` runs through
/// `ctx.NoSQL` (Cassandra). The runner records the applied version in the
/// matching backend's `zero_migrations` table.
pub const Target = enum { relational, nosql };

migrationNumber: i64 = undefined,
target: Target = .relational,
run: *const fn (*root.Context) anyerror!void = undefined,
