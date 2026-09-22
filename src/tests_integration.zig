const std = @import("std");

// Root module for integration tests that require a real database driver. These
// are intentionally excluded from the kcov coverage step (the native driver
// aborts under ptrace) and run via `zig build test-integration`.
//
// Also hosted here: the HTTP-mock-backed datasource tests (ClickHouse,
// Couchbase, InfluxDB, Solr) and the `FakeServer` self-test. They drive the
// `zul` client over loopback through `FakeServer`, which aborts/hangs under
// kcov's ptrace and would blank the whole coverage report. The outbound-auth
// header tests are kept here too, since `outbound_auth.zig` is reachable from
// the unit build (via `client.zig`) and its test blocks would otherwise run
// under the traced `unit_tests` artifact. Keeping all of these in this
// non-coverage build lets them run without poisoning `zig build -Dcoverage test`.
pub const integration = @import("datasource/integration_test.zig");
pub const clickhouse = @import("datasource/clickhouse_test.zig");
pub const couchbase = @import("datasource/couchbase_test.zig");
pub const fakeserver = @import("datasource/fakeserver.zig");
pub const influxdb = @import("datasource/specialized/influxdb_test.zig");
pub const solr = @import("datasource/specialized/solr_test.zig");
pub const outboundAuth = @import("service/outbound_auth.zig");

comptime {
    _ = integration;
    _ = clickhouse;
    _ = couchbase;
    _ = fakeserver;
    _ = influxdb;
    _ = solr;
    _ = outboundAuth;
}
