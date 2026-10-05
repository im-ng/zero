const std = @import("std");
const migrate = @This();
const Self = @This();

const root = @import("../zero.zig");
const util = root.utils;

/// Which datasource a migration applies to. `.relational` runs through the
/// active `ctx.SQL` (postgres/sqlite/duckdb/clickhouse); `.nosql` runs through
/// `ctx.NoSQL` (Cassandra/Couchbase). The runner records the applied version in
/// the matching backend's `zero_migrations` table.
pub const Target = enum { relational, nosql };

migrationNumber: i64 = undefined,
target: Target = .relational,
/// Restrict a relational migration to one SQL dialect. `null` (default) applies
/// to any active relational backend. The runner skips the migration when the
/// live dialect does not match, so a pack can ship postgres/sqlite/duckdb/
/// clickhouse DDL side by side and only the active dialect's version runs.
dialect: ?root.datasourceInterface.Dialect = null,
/// Restrict a NoSQL migration to one backend. `null` (default) applies to any
/// active NoSQL backend. Set to `.cassandra` / `.couchbase` so a pack can carry
/// CQL and N1QL DDL together without cross-applying.
backend: ?root.nosqlInterface.Backend = null,
run: *const fn (*root.Context) anyerror!void = undefined,
