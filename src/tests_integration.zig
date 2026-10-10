const std = @import("std");

// Root module for integration tests that require a real database driver. These
// are intentionally excluded from the kcov coverage step (the native driver
// aborts under ptrace) and run via `zig build test-integration`.
//
// Also hosted here: the HTTP-mock-backed datasource tests (ClickHouse,
// Couchbase, InfluxDB, Solr) and the `FakeServer` self-test. They drive the
// `zul` client over loopback through `FakeServer`, which aborts/hangs under
// kcov's ptrace and would blank the whole coverage report. The outbound-auth
// header tests are kept here too, since `outboundAuth.zig` is reachable from
// the unit build (via `client.zig`) and its test blocks would otherwise run
// under the traced `unit_tests` artifact. Keeping all of these in this
// non-coverage build lets them run without poisoning `zig build -Dcoverage test`.
pub const integration = @import("datasource/integration_test.zig");
pub const clickhouse = @import("datasource/sql/clickhouse_test.zig");
pub const couchbase = @import("datasource/nosql/couchbase_tests.zig");
pub const arangodb = @import("datasource/nosql/arangodb_tests.zig");
pub const fakeserver = @import("datasource/fakeserver.zig");
pub const influxdb = @import("datasource/timeseries/influxdb_test.zig");
pub const opentsdb = @import("datasource/timeseries/opentsdb_test.zig");
pub const solr = @import("datasource/search/solr_test.zig");
pub const meili = @import("datasource/search/meili_test.zig");
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
    _ = solr;
    _ = meili;
    _ = dgraph;
    _ = outboundAuth;
    _ = sqs;
    _ = gcppubsub;
}
