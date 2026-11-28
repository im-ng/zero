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

pub fn loadNoSQL(c: *Container) !void {
    const cassandra_cp = c.config.get("CASSANDRA_CONTACT_POINTS");
    if (!std.mem.eql(u8, cassandra_cp, "")) {
        const keyspace = c.config.get("CASSANDRA_KEYSPACE");
        if (std.mem.eql(u8, keyspace, "")) {
            c.log.err("nosql connection failed: CASSANDRA_KEYSPACE must be set.");
            return;
        }

        const user_val = c.config.get("CASSANDRA_USER");
        const pass_val = c.config.get("CASSANDRA_PASSWORD");
        const tls_enabled = c.config.getAsBool("CASSANDRA_TLS_ENABLED");
        const tls_verify = c.config.getAsBool("CASSANDRA_TLS_VERIFY");
        const tls_ca = c.config.get("CASSANDRA_TLS_CA");
        const tls_server_name = c.config.get("CASSANDRA_TLS_SERVER_NAME");
        const tls_cert_file = c.config.get("CASSANDRA_TLS_CERT_FILE");
        const tls_key_file = c.config.get("CASSANDRA_TLS_KEY_FILE");

        const handle = try root.NoSQL.build(c, .cassandra, .{
            .contact_points = cassandra_cp,
            .keyspace = keyspace,
            .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
            .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
            .tls_enabled = tls_enabled,
            .tls_verify = tls_verify,
            .tls_ca_path = if (std.mem.eql(u8, tls_ca, "")) null else tls_ca,
            .tls_server_name = if (std.mem.eql(u8, tls_server_name, "")) null else tls_server_name,
            .tls_cert_file = if (std.mem.eql(u8, tls_cert_file, "")) null else tls_cert_file,
            .tls_key_file = if (std.mem.eql(u8, tls_key_file, "")) null else tls_key_file,
        });

        c.NoSQL = handle;
        c.nosql_backend = .cassandra;
        c.log.info(try std.fmt.allocPrint(
            c.bootstrap,
            "connected to cassandra at '{s}' (keyspace '{s}'){s}",
            .{ cassandra_cp, keyspace, if (tls_enabled) " (tls)" else "" },
        ));

        return;
    }

    const couchbase_cp = c.config.get("COUCHBASE_CONTACT_POINTS");
    if (!std.mem.eql(u8, couchbase_cp, "")) {
        const bucket = c.config.get("COUCHBASE_BUCKET");
        if (std.mem.eql(u8, bucket, "")) {
            c.log.err("nosql connection failed: COUCHBASE_BUCKET must be set.");
            return;
        }

        const user_val = c.config.get("COUCHBASE_USER");
        const pass_val = c.config.get("COUCHBASE_PASSWORD");
        const handle = try root.NoSQL.build(c, .couchbase, .{
            .contact_points = couchbase_cp,
            .keyspace = bucket,
            .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
            .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
        });

        c.NoSQL = handle;
        c.nosql_backend = .couchbase;
        c.log.info(try std.fmt.allocPrint(
            c.bootstrap,
            "connected to couchbase at '{s}' (bucket '{s}') via N1QL/HTTP",
            .{ couchbase_cp, bucket },
        ));

        return;
    }

    const mongo_cp = c.config.get("MONGODB_CONTACT_POINTS");
    if (!std.mem.eql(u8, mongo_cp, "")) {
        const mongo_db = c.config.get("MONGODB_DB");
        if (std.mem.eql(u8, mongo_db, "")) {
            c.log.err("nosql connection failed: MONGODB_DB must be set.");
            return;
        }

        const mongo_user = c.config.get("MONGODB_USER");
        const mongo_pass = c.config.get("MONGODB_PASSWORD");
        const mongo_tls = std.mem.eql(u8, c.config.get("MONGODB_TLS"), "true");
        const mongo_verify = std.mem.eql(u8, c.config.get("MONGODB_TLS_VERIFY"), "true");
        const mongo_ca = c.config.get("MONGODB_TLS_CA");
        const mongo_auth = c.config.get("MONGODB_AUTH_SOURCE");
        const mongo_tls_sni = c.config.get("MONGODB_TLS_SERVER_NAME");
        const mongo_cert = c.config.get("MONGODB_TLS_CERT_FILE");
        const mongo_key = c.config.get("MONGODB_TLS_KEY_FILE");

        const m = root.MongoDB.create(c.allocator, .{
            .contact_points = mongo_cp,
            .user = if (std.mem.eql(u8, mongo_user, "")) "" else mongo_user,
            .pass = if (std.mem.eql(u8, mongo_pass, "")) "" else mongo_pass,
            .auth_source = if (std.mem.eql(u8, mongo_auth, "")) "admin" else mongo_auth,
            .db = mongo_db,
            .tls_enabled = mongo_tls,
            .tls_verify = mongo_verify,
            .tls_ca_path = if (std.mem.eql(u8, mongo_ca, "")) null else mongo_ca,
            .tls_server_name = if (std.mem.eql(u8, mongo_tls_sni, "")) null else mongo_tls_sni,
            .tls_cert_file = if (std.mem.eql(u8, mongo_cert, "")) null else mongo_cert,
            .tls_key_file = if (std.mem.eql(u8, mongo_key, "")) null else mongo_key,
        }) catch |err| {
            c.log.err("could not initialize mongodb backend");
            c.log.any(err);
            return;
        };

        const handle = try c.allocator.create(root.NoSQL);
        handle.* = root.NoSQL.init(m, .mongodb, null, c.metricz);
        c.NoSQL = handle;
        c.nosql_backend = .mongodb;

        c.log.info(try std.fmt.allocPrint(
            c.bootstrap,
            "connected to mongodb at '{s}' (db '{s}'){s}",
            .{ mongo_cp, mongo_db, if (mongo_tls) " (tls)" else "" },
        ));
        return;
    }

    c.log.debug("nosql is disabled, as CONTACT_POINTS are not provided.");
}

pub fn loadNoSQLArango(c: *Container) !void {
    const host = c.config.get("ARANGO_HOST");
    if (std.mem.eql(u8, host, "")) {
        c.log.debug("arangodb is disabled, as ARANGO_HOST is not provided.");
        return;
    }

    const db = c.config.get("ARANGO_DB");
    if (std.mem.eql(u8, db, "")) {
        c.log.err("nosql connection failed: ARANGO_DB must be set.");
        return;
    }

    const user_val = c.config.get("ARANGO_USER");
    const pass_val = c.config.get("ARANGO_PASSWORD");
    const handle = try root.NoSQL.build(c, .arangodb, .{
        .contact_points = host,
        .keyspace = db,
        .user = if (std.mem.eql(u8, user_val, "")) null else user_val,
        .password = if (std.mem.eql(u8, pass_val, "")) null else pass_val,
    });

    c.NoSQL = handle;
    c.nosql_backend = .arangodb;
    c.log.info(try std.fmt.allocPrint(
        c.bootstrap,
        "connected to arangodb at '{s}' (db '{s}')",
        .{ host, db },
    ));
}

pub fn loadGraph(c: *Container) !void {
    const url = c.config.get("DGRAPH_URL");
    if (std.mem.eql(u8, url, "")) {
        c.log.debug("graph is disabled, as DGRAPH_URL is not provided.");
        return;
    }

    const key = c.config.get("DGRAPH_API_KEY");
    const handle = try root.Graph.build(c, .dgraph, .{
        .url = url,
        .api_key = if (std.mem.eql(u8, key, "")) null else key,
    });
    c.Graph = handle;
    c.log.info(try std.fmt.allocPrint(c.bootstrap, "connected to dgraph at '{s}'", .{url}));
}
