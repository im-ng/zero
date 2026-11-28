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

pub fn loadSearch(c: *Container) !void {
    // Meilisearch takes priority when configured.
    const meili_host = c.config.get("MEILI_HOST");
    if (!std.mem.eql(u8, meili_host, "")) {
        const index = c.config.get("MEILI_INDEX");
        if (std.mem.eql(u8, index, "")) {
            c.log.err("search connection failed: MEILI_INDEX must be set.");
            return;
        }

        const key = c.config.get("MEILI_API_KEY");
        const handle = try root.Search.build(c, .meilisearch, .{
            .url = meili_host,
            .default_collection = index,
            .api_key = if (std.mem.eql(u8, key, "")) null else key,
        });

        c.Search = handle;
        c.log.info(try std.fmt.allocPrint(
            c.bootstrap,
            "connected to meilisearch at '{s}' (index '{s}')",
            .{ meili_host, index },
        ));

        return;
    }

    const url = c.config.get("SOLR_URL");
    if (std.mem.eql(u8, url, "")) {
        c.log.debug("search is disabled, as SOLR_URL is not provided.");

        return;
    }

    const collection = c.config.get("SOLR_DEFAULT_COLLECTION");
    if (std.mem.eql(u8, collection, "")) {
        c.log.err("search connection failed: SOLR_DEFAULT_COLLECTION must be set.");

        return;
    }

    const auth_val = c.config.get("SOLR_BASIC_AUTH");
    const handle = try root.Search.build(c, .solr, .{
        .url = url,
        .default_collection = collection,
        .basic_auth = if (std.mem.eql(u8, auth_val, "")) null else auth_val,
    });
    c.Search = handle;

    c.log.info(try std.fmt.allocPrint(
        c.bootstrap,
        "connected to solr at '{s}' (default collection '{s}')",
        .{ url, collection },
    ));
}
