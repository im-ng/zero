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

pub fn loadFileStore(c: *Container) !void {
    const backend_name = c.config.getOrDefault("FILE_STORE_BACKEND", "local");

    if (std.mem.eql(u8, backend_name, "s3")) {
        const store = root.filestore.build(c, .s3, .{}) catch |err| {
            c.log.err("could not initialize s3 file store");
            c.log.any(err);
            return;
        };
        try c.fileStores.put("s3", store);
        if (c.defaultFileStore == null) {
            c.defaultFileStore = store;
        }
        c.log.info("connected to s3 file store");
        return;
    }

    if (std.mem.eql(u8, backend_name, "supabase")) {
        const store = root.filestore.build(c, .supabase, .{}) catch |err| {
            c.log.err("could not initialize supabase file store");
            c.log.any(err);
            return;
        };
        try c.fileStores.put("supabase", store);
        if (c.defaultFileStore == null) {
            c.defaultFileStore = store;
        }
        c.log.info("connected to supabase file store");
        return;
    }

    if (std.mem.eql(u8, backend_name, "gcs")) {
        const store = root.filestore.build(c, .gcs, .{}) catch |err| {
            c.log.err("could not initialize gcs file store");
            c.log.any(err);
            return;
        };
        try c.fileStores.put("gcs", store);
        if (c.defaultFileStore == null) {
            c.defaultFileStore = store;
        }
        c.log.info("connected to gcs file store");
        return;
    }

    const root_dir = c.config.getOrDefault("FILE_STORE_ROOT", "");
    if (std.mem.eql(u8, root_dir, "")) {
        c.log.debug("file store is disabled, as FILE_STORE_ROOT is not provided.");
        return;
    }

    const store = root.filestore.build(c, .local, .{ .root = root_dir }) catch |err| {
        c.log.err("could not initialize local file store");
        c.log.any(err);
        return;
    };

    try c.fileStores.put("local", store);
    if (c.defaultFileStore == null) {
        c.defaultFileStore = store;
    }

    c.log.info("connected to local file store");
}
