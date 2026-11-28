const std = @import("std");
const root = @import("../zero.zig");
const Container = @import("container.zig");

const Metricz = root.metricz;
const constants = root.constants;
const Context = root.Context;
const utils = root.utils;
const rediz = root.rediz;
const rdzClient = root.rediz.Client;
const rdzDatasource = root.rdz;
const zeroClient = root.client;
const MQTT = root.MQTT;
const mqConfig = root.mqConfig;
const natsConfig = root.natsConfig;
const rdkafka = root.rdkafka;
const kafka = root.kafka;
const build_options = @import("build_options");

pub fn loadMetricz(c: *Container) !void {
    // Resolve the per-metric label-cardinality cap from config (which honors
    // `configs/.env`). Absent => default (initialize applies 4096); `0` => disabled;
    // positive => that value. This replaces the old `std.c.environ` read so
    // config-driven limits actually take effect. `0` must be passed through, not
    // collapsed to null, or it becomes indistinguishable from "unset".
    const card_present = !std.mem.eql(u8, c.config.get("METRICS_CARDINALITY_LIMIT"), "");
    const card_raw = c.config.getAsInt("METRICS_CARDINALITY_LIMIT") catch 0;
    const cap_override: ?usize = if (!card_present) null else card_raw;

    // initialize metrics
    c.metricz = try Metricz.initialize(c.allocator, .{ .prefix = "", .exclude = null }, cap_override);

    // app metrics
    try c.metricz.info(.{ .app_name = c.appName, .app_version = c.appVersion, .zero_version = "0.0.1" });

    try c.metricz.appThreads(.{ .label = "app_threads" }, 0);

    try c.metricz.appMemoryUsage(.{ .label = "app_memory_usage" }, 0);

    try c.metricz.appMemoryTotal(.{ .label = "app_memory_total" }, 0);

    // http metrics
    try c.metricz.response(.{ .path = "/", .method = "GET", .status = 200 }, 0);

    // redis metrics
    // todo

    // pub/sub metrics
    // todo

    // SQL metrics
    try c.metricz.sqlResponse(.{ .hostname = "", .database = "", .query = "", .operation = "select" }, 0);
}
