pub const std = @import("std");
pub const constants = @import("constants.zig");

// zero dependencies
pub const zul = @import("zul");
pub const pgz = @import("pg");
pub const httpz = @import("httpz");
// pub const metriks = @import("metricz");
pub const rediz = @import("rediz");
pub const dotenv = @import("dotenv");
pub const zdt = @import("zdt");
pub const regexp = @import("regexp");
pub const mqttz = @import("mqttz");
pub const jwt = @import("jwt");
pub const natslib = @import("nats");

// GraphQL parser (graphql-zig) + zero's executor engine (src/graphql.zig).
pub const graphql = @import("graphql");
pub const gql = @import("graphql.zig");

pub const rdkafka = @import("cimport.zig").librdkafka;
pub const sqlitez = @import("sqlite");

pub const protobuf = @import("protobuf");

// Cross-platform system-info (zf). Powers the zsutil cpu/host/memory wrappers
// so examples like zero-stream run on macOS without reading /proc.
pub const sysinfo = @import("zf");

// zero internals
pub const logger = @import("logger.zig");
pub const config = @import("config.zig");
pub const metricz = @import("metricz.zig");
pub const container = @import("container.zig");
pub const context = @import("context.zig");
pub const Context = @import("context.zig").Context;
pub const utils = @import("utils.zig");
pub const metriczServer = @import("metriczServer.zig");
pub const httpServer = @import("httpServer.zig");
pub const handler = @import("handler.zig");
pub const responder = @import("responder.zig");
pub const tracz = @import("mw/tracz.zig");
pub const otel = @import("otel.zig");
pub const rateLimiter = @import("mw/rateLimiter.zig");
pub const kvstore = @import("kvstore/interface.zig");
pub const KVStore = kvstore.KVStore;
pub const filestore = @import("filestore/interface.zig");
pub const FileStore = filestore.FileStore;
pub const UploadedFile = filestore.UploadedFile;

pub const autocrud = @import("autocrud.zig");
pub const AutoCrudOptions = autocrud.AutoCrudOptions;
pub const addRestHandlers = autocrud.addRestHandlers;

pub const authz = @import("mw/authz.zig");
pub const AuthProvider = @import("mw/authProvider.zig");
pub const jwtClaims = AuthProvider.jwtClaims;
pub const rbac = @import("mw/rbac.zig");

pub const rdz = @import("datasource/rdz.zig");
pub const SQL = @import("datasource/SQL.zig");

pub const SQLite = @import("datasource/SQLite.zig");

pub const DuckDB = @import("datasource/DuckDB.zig").DuckDB;
pub const DuckGres = @import("datasource/duckgres.zig").DuckGres;
pub const ClickHouse = @import("datasource/ClickHouse.zig").ClickHouse;
pub const datasourceInterface = @import("datasource/interface.zig");
pub const Datasource = datasourceInterface.Interface;

pub const migration = @import("migration/migration.zig");
pub const migrate = @import("migration/migrate.zig");

// Specialized datasources (time-series / search)
pub const timeseriesInterface = @import("datasource/specialized/timeseriesInterface.zig");
pub const Timeseries = timeseriesInterface.Timeseries;
pub const InfluxDB = @import("datasource/specialized/influxdb.zig").InfluxDB;

pub const searchInterface = @import("datasource/specialized/searchInterface.zig");
pub const Search = searchInterface.Search;
pub const Solr = @import("datasource/specialized/solr.zig").Solr;

// NoSQL datasource (document / wide-column)
pub const nosqlInterface = @import("datasource/nosqlInterface.zig");
pub const NoSQL = nosqlInterface.NoSQL;
pub const Couchbase = @import("datasource/couchbase.zig").Couchbase;
pub const NoSQLBackend = @import("datasource/nosql.zig").NoSQL;
pub const MongoDB = @import("datasource/mongodb.zig").MongoDB;

pub const client = @import("service/client.zig");
pub const circuit_breaker = @import("service/circuit_breaker.zig");
pub const Error = @import("http/errors.zig");

pub const scheduler = @import("cronz/scheduler.zig");
pub const cronz = @import("cronz/cronz.zig");
pub const cronJob = @import("cronz/job.zig");
pub const tick = @import("cronz/tick.zig");

pub const mqConfig = @import("pubsub/mqtt/config.zig");
pub const mqSubscriber = @import("pubsub/mqtt/subscriber.zig");
pub const mqMessage = @import("pubsub/mqtt/message.zig");
pub const MQTT = @import("pubsub/mqtt/MQTT.zig");

pub const kafka = @import("pubsub/kafka/kafka.zig");
pub const kafkaSubscriber = @import("pubsub/kafka/subscriber.zig");
pub const kafkaMessage = @import("pubsub/kafka/message.zig").Message;

pub const natsConfig = @import("pubsub/nats/config.zig").natsConfig;
pub const natsSubscriber = @import("pubsub/nats/subscriber.zig").natsSubscriber;
pub const natsMessage = @import("pubsub/nats/message.zig").natsMessage;
pub const nats = @import("pubsub/nats/NATS.zig").NATS;

pub const redisMessage = @import("pubsub/redis/message.zig").redisMessage;
pub const redisPubSub = @import("pubsub/redis/Redis.zig").Redis;

pub const pubsubInterface = @import("pubsub/interface.zig");
pub const PubSub = pubsubInterface.Interface;

pub const WSHandler = @import("websocket.zig");
pub const WSMiddleware = @import("mw/ws.zig");
pub const WSClient = httpz.websocket.Conn;

// swagger files
pub const favIcon = @embedFile("static/favicon.ico");
pub const indexCss = @embedFile("static/index.css");
pub const indexHtml = @embedFile("static/index.html");
pub const oauthRedirect = @embedFile("static/oauth2-redirect.html");
pub const oauthRedirectJs = @embedFile("static/oauth2-redirect.js");
pub const swaggerInitializerJs = @embedFile("static/swagger-initializer.js");
pub const swaggerUIBundle = @embedFile("static/swagger-ui-bundle.js");
pub const swaggerUIBundlerPreset = @embedFile("static/swagger-ui-standalone-preset.js");
pub const swaggerUICss = @embedFile("static/swagger-ui.css");
pub const swaggerUIJs = @embedFile("static/swagger-ui.js");

pub const memory = @import("zsutil/memory.zig");
pub const cpu = @import("zsutil/cpu.zig");
pub const process = @import("zsutil/process.zig");
pub const host = @import("zsutil/host.zig");

pub const App = @import("app.zig");

pub const std_options: std.Options = .{
    .logFn = logger.custom,
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);
    return @import("cli.zig").run(init.minimal.args);
}
