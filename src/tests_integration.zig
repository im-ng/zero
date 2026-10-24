const std = @import("std");

// Root module for integration tests that require a real database driver. These
// are intentionally excluded from the kcov coverage step and run via
// `zig build test-integration`.
//
// Also hosted here: the HTTP-mock-backed datasource tests (ClickHouse,
// Couchbase, InfluxDB) and the `FakeServer` self-test. They drive the
// `zul` client over loopback through `FakeServer`. Verified under kcov 43 with
// the `.use_llvm` unit-test build: a FakeServer loopback test and
// a `sqlitez.Db.init` test both pass the traced run, so the older "aborts under
// kcov's ptrace" claim no longer holds for this toolchain. These stay in this
// non-coverage build because they bind real native libraries / extra server
// machinery and we keep the traced `unit_tests` artifact lean. The search
// clients' FakeServer tests (meili/solr) DO live in the traced unit build —
// they are the only coverage for those modules (see src/tests.zig).
pub const integration = @import("datasource/integration_test.zig");
pub const clickhouse = @import("datasource/sql/clickhouse_test.zig");
pub const couchbase = @import("datasource/nosql/couchbase_tests.zig");
pub const arangodb = @import("datasource/nosql/arangodb_tests.zig");
pub const fakeserver = @import("datasource/fakeserver.zig");
pub const influxdb = @import("datasource/timeseries/influxdb_test.zig");
pub const opentsdb = @import("datasource/timeseries/opentsdb_test.zig");
pub const dgraph = @import("datasource/graph/dgraph_test.zig");
pub const gcs = @import("filestore/gcs_test.zig");
pub const sqs = @import("pubsub/sqs_test.zig");
pub const gcppubsub = @import("pubsub/gcppubsub_test.zig");
pub const outboundAuth = @import("service/outboundAuth.zig");

comptime {
    _ = integration;
    _ = clickhouse;
    _ = couchbase;
    _ = arangodb;
    _ = fakeserver;
    _ = influxdb;
    _ = opentsdb;
    _ = dgraph;
    _ = outboundAuth;
    _ = sqs;
    _ = gcppubsub;
}
