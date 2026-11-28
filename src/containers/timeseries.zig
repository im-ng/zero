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

pub fn loadTimeseries(c: *Container) !void {
    const url = c.config.get("INFLUXDB_URL");
    if (std.mem.eql(u8, url, "")) {
        c.log.debug("time-series is disabled, as INFLUXDB_URL is not provided.");
        return;
    }

    const bucket = c.config.get("INFLUXDB_BUCKET");
    if (std.mem.eql(u8, bucket, "")) {
        c.log.err("time-series connection failed: INFLUXDB_BUCKET must be set.");
        return;
    }

    const token = c.config.get("INFLUXDB_TOKEN");
    if (std.mem.eql(u8, token, "")) {
        c.log.err("time-series connection failed: INFLUXDB_TOKEN must be set.");
        return;
    }

    const handle = try root.Timeseries.build(c, .influxdb, .{
        .url = url,
        .bucket = bucket,
        .token = token,
    });

    c.Timeseries = handle;

    c.log.info(try std.fmt.allocPrint(c.bootstrap, "connected to influxdb at '{s}' (db '{s}')", .{ url, bucket }));
}

pub fn loadTimeseriesOpenTSDB(c: *Container) !void {
    const url = c.config.get("OPENTSDB_URL");
    if (std.mem.eql(u8, url, "")) {
        c.log.debug("opentsdb is disabled, as OPENTSDB_URL is not provided.");
        return;
    }

    const token = c.config.get("OPENTSDB_TOKEN");
    const handle = try root.Timeseries.build(c, .opentsdb, .{
        .url = url,
        .bucket = "",
        .token = if (std.mem.eql(u8, token, "")) null else token,
    });

    c.Timeseries = handle;
    c.log.info(try std.fmt.allocPrint(c.bootstrap, "connected to opentsdb at '{s}'", .{url}));
}
