pub const std = @import("std");
pub const constants = @import("constants.zig");

// zero dependencies
pub const zul = @import("zul");
pub const pgz = @import("pg");
pub const httpz = @import("httpz");
pub const metriks = @import("metriks");
pub const rediz = @import("rediz");
pub const dotenv = @import("dotenv");
pub const zdt = @import("zdt");
pub const regexp = @import("regexp");
pub const mqttz = @import("mqttz");
pub const jwt = @import("jwt");

pub const rdkafka = @import("cimport.zig").librdkafka;

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
pub const authz = @import("mw/authz.zig");
pub const AuthProvder = @import("mw/authProvider.zig");
pub const jwtClaims = AuthProvder.jwtClaims;

pub const rdz = @import("datasource/rdz.zig");
pub const SQL = @import("datasource/SQL.zig");
pub const migration = @import("migration/migration.zig");
pub const migrate = @import("migration/migrate.zig");

pub const client = @import("service/client.zig");
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

fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var ix: usize = 0;
    std.log.err("=== Stack Trace ==============", .{});
    while (it.next()) |frame| : (ix += 1) {
        std.log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }
}
