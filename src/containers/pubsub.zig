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

pub fn loadPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const pubsub = c.config.get("PUBSUB_BACKEND");
    if (std.mem.eql(u8, pubsub, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, "KAFKA", pubsub)) {
        try loadKafkaPubSub(c);
    } else if (std.mem.eql(u8, "MQTT", pubsub)) {
        try loadMqttPubSub(c);
    } else if (std.mem.eql(u8, "NATS", pubsub)) {
        try loadNatsPubSub(c);
    } else if (std.mem.eql(u8, "REDIS", pubsub)) {
        try loadRedisPubSub(c);
    } else if (std.mem.eql(u8, "SQS", pubsub)) {
        try loadSqsPubSub(c);
    } else if (std.mem.eql(u8, "GCP", pubsub) or std.mem.eql(u8, "GOOGLE", pubsub)) {
        try loadGcpPubSub(c);
    } else {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        c.log.debug(buffer);
    }
}

pub fn loadKafkaPubSub(c: *Container) !void {
    if (comptime !build_options.kafka) return;
    var mode: c_uint = rdkafka.RD_KAFKA_PRODUCER;

    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 1024);

    var error_message: [512]u8 = undefined;
    const servers = c.config.get("PUBSUB_BROKER");
    if (std.mem.eql(u8, servers, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as broker(s) is/are not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const consumerID = c.config.get("CONSUMER_ID");
    const batchBytes = c.config.getOrDefault("KAFKA_BATCH_BYTES", "1048576");
    const batchTimeout = c.config.getOrDefault("KAFKA_BATCH_TIMEOUT", "1000");
    const batchSize = c.config.getOrDefault("KAFKA_BATCH_SIZE", "100");

    const saslProtocol = c.config.getOrDefault("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT");
    const saslMechanism = c.config.getOrDefault("KAFKA_SASL_MECHANISM", "PLAIN");
    const saslUsername = c.config.get("KAFKA_SASL_USERNAME");
    const saslPassword = c.config.get("KAFKA_SASL_PASSWORD");

    const kafkaTlsCertFile = c.config.get("KAFKA_TLS_CERT_FILE");
    const kafkaTlsKeyFile = c.config.get("KAFKA_TLS_KEY_FILE");
    const kafkaTlsCACertFile = c.config.get("KAFKA_TLS_CA_CERT_FILE");
    const kafkaTlsSkipVerify = c.config.getOrDefault("KAFKA_TLS_INSECURE_SKIP_VERIFY", "false");

    const config: ?*rdkafka.struct_rd_kafka_conf_s = rdkafka.rd_kafka_conf_new();

    if (kafkaConfSet(c, buffer, config, "bootstrap.servers", servers, &error_message)) {
        return error.KafkaConfigError;
    }

    if (std.mem.eql(u8, consumerID, "") == false) {
        mode = rdkafka.RD_KAFKA_CONSUMER;

        if (kafkaConfSet(c, buffer, config, "group.id", consumerID, &error_message)) {
            return error.KafkaConfigError;
        }
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = kafkaConfSet(c, buffer, config, "batch.num.messages", batchSize, &error_message);
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = kafkaConfSet(c, buffer, config, "request.timeout.ms", batchTimeout, &error_message);
    }

    if (mode == rdkafka.RD_KAFKA_PRODUCER) {
        _ = kafkaConfSet(c, buffer, config, "batch.size", batchBytes, &error_message);
    }

    if (saslProtocol.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "security.protocol", saslProtocol, &error_message);
    }

    if (saslMechanism.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "sasl.mechanism", saslMechanism, &error_message);
    }

    if (saslUsername.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "sasl.username", saslUsername, &error_message);
    }

    if (saslPassword.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "sasl.password", saslPassword, &error_message);
    }

    if (kafkaTlsKeyFile.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "ssl.key.location", kafkaTlsKeyFile, &error_message);
    }

    if (kafkaTlsCertFile.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "ssl.certificate.location", kafkaTlsCertFile, &error_message);
    }

    if (kafkaTlsCACertFile.len > 0) {
        _ = kafkaConfSet(c, buffer, config, "ssl.ca.location", kafkaTlsCACertFile, &error_message);
    }

    _ = kafkaConfSet(c, buffer, config, "enable.ssl.certificate.verification", kafkaTlsSkipVerify, &error_message);

    c.log.info(try std.fmt.bufPrint(buffer, "connecting to kafka at '{s}'", .{servers}));

    c.Kafka = kafka.create(c, config, null, mode) catch |err| {
        buffer = try c.bootstrap.alloc(u8, 1024);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to kafka at '{s}'", .{servers});
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    c.log.info(try std.fmt.bufPrint(buffer, "connected to kafka at '{s}'", .{servers}));

    switch (mode) {
        rdkafka.RD_KAFKA_PRODUCER => {
            c.log.info("kafka publisher mode enabled");
        },
        rdkafka.RD_KAFKA_CONSUMER => {
            c.log.info("kafka subscriber mode enabled");
        },
        else => {
            //do nothing
        },
    }

    // build the unified PubSub dispatcher
    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.Kafka)), .vtable = &root.kafka.vtable };
    c.pubSub = ps;
}

pub fn kafkaConfSet(
    c: *Container,
    log_buf: []u8,
    config: ?*rdkafka.struct_rd_kafka_conf_s,
    key: []const u8,
    value: []const u8,
    err_buf: *[512]u8,
) bool {
    if (rdkafka.rd_kafka_conf_set(config, key.ptr, value.ptr, err_buf, err_buf.len) != rdkafka.RD_KAFKA_CONF_OK) {
        _ = std.fmt.bufPrint(log_buf, "connection to kafka failed: error occurred {s}", .{err_buf.*}) catch |err| {
            c.log.any(err);
            return true;
        };

        c.log.err(log_buf);
        return true;
    }
    return false;
}

pub fn loadMqttPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const pubsub = c.config.get("PUBSUB_BACKEND");
    if (std.mem.eql(u8, pubsub, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as pubsub mode is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    if (std.mem.eql(u8, pubsub, "MQTT") == false) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, not valid backend provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const hostname = c.config.get("MQTT_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as mqtt host is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const port = c.config.get("MQTT_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "connection to mqtt failed: mqtt port is empty.", .{});
        c.log.err(buffer);
        return;
    }

    // const protocol = c.config.getOrDefault("MQTT_PROTOCOL", "tcp");
    const username = c.config.getOrDefault("MQTT_USER", "");
    const password = c.config.getOrDefault("MQTT_PASSWORD", "");
    const clientID = c.config.getOrDefault("MQTT_CLIENT_ID_SUFFIX", "-none");
    // const keepalive = c.config.getAsBool("MQTT_KEEP_ALIVE");
    const portAsInt = try c.config.getAsInt("MQTT_PORT");
    const qos = try c.config.getAsInt("MQTT_QOS");
    const retain = c.config.getAsBool("MQTT_RETRIEVE_RETAINED");

    const config = &mqConfig{
        .clientID = clientID,
        .hostname = hostname,
        .ip = hostname,
        .username = username,
        .password = password,
        .keepAliveDuaration = 1,
        .qos = qos,
        .retainOnRetrieval = retain,
        .port = portAsInt,
        .connectionTimeout = 10_000,
    };

    buffer = try c.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connecting to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    c.log.info(buffer);

    c.mqtt = MQTT.create(c, config) catch |err| {
        buffer = try c.bootstrap.alloc(u8, 256);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    if (c.mqtt) |pb| {
        try pb.mqtt.ping(.{});
    }

    buffer = try c.bootstrap.alloc(u8, 256);
    buffer = try std.fmt.bufPrint(buffer, "connected to MQTT at '{s}:{d}'", .{ hostname, portAsInt });
    c.log.info(buffer);

    // build the unified PubSub dispatcher
    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.mqtt)), .vtable = &root.MQTT.vtable };
    c.pubSub = ps;
}

pub fn loadNatsPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 512);

    const url = c.config.get("PUBSUB_BROKER");
    if (std.mem.eql(u8, url, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "pubsub is disabled, as nats broker is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const stream = c.config.get("NATS_STREAM");
    const subjects = c.config.getOrDefault("NATS_SUBJECTS", "");
    const max_wait = try c.config.getAsInt("NATS_MAX_WAIT");
    const max_pull_wait = try c.config.getAsInt("NATS_MAX_PULL_WAIT");
    const consumer = c.config.get("NATS_CONSUMER");
    const creds_file = c.config.get("NATS_CREDS_FILE");

    const config = natsConfig{
        .url = url,
        .stream = stream,
        .subjects = subjects,
        .max_wait_ms = @intCast(max_wait),
        .max_pull_wait_ms = @intCast(max_pull_wait),
        .consumer = consumer,
        .creds_file = creds_file,
    };

    c.Nats = root.nats.create(c, &config) catch |err| {
        buffer = try c.bootstrap.alloc(u8, 256);
        buffer = try std.fmt.bufPrint(buffer, "could not connect to NATS at '{s}'", .{url});
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    // build the unified PubSub dispatcher
    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.Nats)), .vtable = &root.nats.vtable };
    c.pubSub = ps;
}

pub fn loadRedisPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 256);

    const hostname = c.config.get("REDIS_HOST");
    if (std.mem.eql(u8, hostname, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis pubsub is disabled, as redis host is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    const port = c.config.get("REDIS_PORT");
    if (std.mem.eql(u8, port, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "redis pubsub is disabled, as redis port is empty.", .{});
        c.log.err(buffer);
        return;
    }

    const user = c.config.get("REDIS_USER");
    const password = c.config.get("REDIS_PASSWORD");
    const dbInt = c.config.getAsInt("REDIS_DB") catch 0;
    const portInt = try c.config.getAsInt("REDIS_PORT");

    c.Redis = root.redisPubSub.create(c, hostname, portInt, user, password, @intCast(dbInt)) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not connect to Redis pubsub at '{s}:{d}'", .{ hostname, portInt });
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.Redis)), .vtable = &root.redisPubSub.vtable };
    c.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "redis pubsub enabled at '{s}:{d}'", .{ hostname, portInt });
    c.log.info(buffer);
}

pub fn loadSqsPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 256);

    const queue_url = c.config.get("SQS_QUEUE_URL");
    if (std.mem.eql(u8, queue_url, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "sqs pubsub is disabled, as SQS_QUEUE_URL is not provided.", .{});
        c.log.debug(buffer);
        return;
    }

    c.Sqs = root.sqs.create(c) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not initialize SQS pubsub", .{});
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.Sqs)), .vtable = &root.sqs.vtable, .native_dlq = true };
    c.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "sqs pubsub enabled at '{s}'", .{queue_url});
    c.log.info(buffer);
}

pub fn loadGcpPubSub(c: *Container) !void {
    var buffer: []u8 = undefined;
    buffer = try c.bootstrap.alloc(u8, 256);

    const project = c.config.get("GCP_PROJECT");
    if (std.mem.eql(u8, project, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "gcp pubsub is disabled, as GCP_PROJECT is not provided.", .{});
        c.log.debug(buffer);
        return;
    }
    const subscription = c.config.get("GCP_SUBSCRIPTION");
    if (std.mem.eql(u8, subscription, "") == true) {
        buffer = try std.fmt.bufPrint(buffer, "gcp pubsub is disabled, as GCP_SUBSCRIPTION is not provided.", .{});
        c.log.err(buffer);
        return;
    }

    c.Gcp = root.gcpPubSub.create(c) catch |err| {
        buffer = try std.fmt.bufPrint(buffer, "could not initialize GCP pubsub", .{});
        c.log.err(buffer);
        c.log.any(err);
        return;
    };

    const ps = try c.allocator.create(root.PubSub);
    ps.* = .{ .ptr = @ptrCast(@alignCast(c.Gcp)), .vtable = &root.gcpPubSub.vtable, .native_dlq = true };
    c.pubSub = ps;

    buffer = try std.fmt.bufPrint(buffer, "gcp pubsub enabled for project '{s}'", .{project});
    c.log.info(buffer);
}
