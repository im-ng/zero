const std = @import("std");

pub const APP_ENVIRONMENT = "APP_ENV";
pub const APP_NAME = "APP_NAME";
pub const APP_VERSION = "APP_VERSION";

pub const METRICZ_PORT: u16 = 2121;
pub const HTTP_PORT: u16 = 8080;

pub const WELL_KNOWN = "./well-known/";
pub const LIVE_PATH = "/.well-known/live";
pub const HEALTH_PATH = "/.well-known/health";
pub const STARTUP_PATH = "/.well-known/startup";
pub const METRICS_PATH = "/metrics";

pub const INDEX_FILE = "index.html";
pub const OPEN_API_PATH = "/.well-known/openapi.json";
pub const SWAGGER_PATH = "/.well-known/swagger";

pub const STATIC_DIR_NAME = "static";
pub const PUBLIC_DIR_NAME = "public";
pub const STATIC_DIR = "./static";
pub const PUBLIC_DIR = "./public";

pub const FAVICON_FILE_PATH = "./static/favicon.ico";
pub const STATUS_UP = "UP";
pub const STATUS_DOWN = "DOWN";

pub const AUTH_HEADER = "authorization";
pub const APIKEY_HEADER = "x-api-key";

pub const REGEXP_SPLITS = "(.*)/(\\d+)";
pub const REGEXP_RANGES = "^(\\d+)-(\\d+)$";

pub const indexCss = "/.well-known/index.css";
pub const indexHtml = "/.well-known/index.html";
pub const oauthRedirect = "/.well-known/oauth2-redirect.html";
pub const oauthRedirectJs = "/.well-known/oauth2-redirect.js";
pub const swaggerInitializerJs = "/.well-known/swagger-initializer.js";
pub const swaggerUIBundle = "/.well-known/swagger-ui-bundle.js";
pub const swaggerUIBundlerPreset = "/.well-known/swagger-ui-standalone-preset.js";
pub const swaggerUICss = "/.well-known/swagger-ui.css";
pub const swaggerUIJs = "/.well-known/swagger-ui.js";
pub const swagger = "/.well-known/swagger";

// --- HTTP server ----------------------------------------------------------
pub const DEFAULT_HTTP_WORKERS: u16 = 2;
pub const DEFAULT_HTTP_MAX_BODY_SIZE_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_HTTP_LARGE_BUFFER_COUNT: u16 = 8;
pub const DEFAULT_HTTP_THREAD_POOL_COUNT: u16 = 32;
pub const DEFAULT_REQUEST_TIMEOUT_MS: u32 = 30000;
pub const DEFAULT_KEEPALIVE_TIMEOUT_MS: u32 = 60;
pub const DEFAULT_RATE_LIMIT_MAX: u64 = 100;
pub const DEFAULT_RATE_LIMIT_WINDOW_MS: i64 = 60_000;
pub const DEFAULT_INBOUND_MAX_CONCURRENT: u32 = 1024;

// --- Container / datasource -----------------------------------------------
pub const DEFAULT_PG_POOL_SIZE: u32 = 10;
pub const DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS: u32 = 10_000;
pub const DEFAULT_NATS_MAX_PULL_WAIT_MS: u32 = 5000;
pub const DEFAULT_STATEMENT_TIMEOUT_MS: u32 = 30000;

// --- App ------------------------------------------------------------------
pub const DEFAULT_FRAMEWORK_MEM_SIZE: usize = 8;
pub const DEFAULT_REMOTE_LOG_REFRESH_INTERVAL_S: u64 = 30;
pub const DEFAULT_HEALTH_CHECK_TIMEOUT_MS: u32 = 3000;

// --- Outbound service / circuit breaker ----------------------------------
pub const DEFAULT_SERVICE_RETRY_BASE_MS: i64 = 100;
pub const DEFAULT_CB_FAILURE_THRESHOLD: u32 = 5;
pub const DEFAULT_CB_COOLDOWN_MS: u64 = 30_000;
pub const DEFAULT_CB_HALF_OPEN_TRIALS: u32 = 1;

// --- Pub/Sub retry (kafka / nats / cronz / redis share these) -------------
pub const DEFAULT_PUBSUB_MAX_ATTEMPTS: u32 = 3;
pub const DEFAULT_PUBSUB_BACKOFF_MS: i64 = 500;

// --- Kafka / filestore / context ------------------------------------------
pub const DEFAULT_KAFKA_FLUSH_MS: u32 = 60_000;
pub const DEFAULT_KAFKA_BATCH_SIZE: u32 = 100;
pub const DEFAULT_FILESTORE_MAX_BYTES_LOCAL: usize = 100 * 1024 * 1024;
pub const DEFAULT_FILESTORE_MAX_BYTES_S3: usize = 64 * 1024 * 1024;
pub const DEFAULT_REQUEST_BODY_LIMIT_BYTES: usize = 100 * 1024 * 1024;

// ===================== Tests =====================

test "constants path values" {
    try std.testing.expectEqualStrings("APP_ENV", APP_ENVIRONMENT);
    try std.testing.expectEqualStrings("APP_NAME", APP_NAME);
    try std.testing.expectEqualStrings("APP_VERSION", APP_VERSION);
}

test "constants port values" {
    try std.testing.expectEqual(@as(u16, 2121), METRICZ_PORT);
    try std.testing.expectEqual(@as(u16, 8080), HTTP_PORT);
}

test "constants status strings" {
    try std.testing.expectEqualStrings("UP", STATUS_UP);
    try std.testing.expectEqualStrings("DOWN", STATUS_DOWN);
}

test "constants header names" {
    try std.testing.expectEqualStrings("authorization", AUTH_HEADER);
    try std.testing.expectEqualStrings("x-api-key", APIKEY_HEADER);
}

test "constants regex patterns" {
    try std.testing.expectEqualStrings("(.*)/(\\d+)", REGEXP_SPLITS);
    try std.testing.expectEqualStrings("^(\\d+)-(\\d+)$", REGEXP_RANGES);
}

test "constants swagger paths" {
    try std.testing.expectEqualStrings("/.well-known/swagger", SWAGGER_PATH);
    try std.testing.expectEqualStrings("/.well-known/index.css", indexCss);
    try std.testing.expectEqualStrings("/.well-known/index.html", indexHtml);
    try std.testing.expectEqualStrings("/.well-known/openapi.json", OPEN_API_PATH);
}

test "constants static paths" {
    try std.testing.expectEqualStrings("static", STATIC_DIR_NAME);
    try std.testing.expectEqualStrings("public", PUBLIC_DIR_NAME);
    try std.testing.expectEqualStrings("./static", STATIC_DIR);
    try std.testing.expectEqualStrings("./public", PUBLIC_DIR);
}

test "constants index paths" {
    try std.testing.expectEqualStrings("index.html", INDEX_FILE);
    try std.testing.expectEqualStrings("./static/favicon.ico", FAVICON_FILE_PATH);
}

test "constants oauth redirect paths" {
    try std.testing.expectEqualStrings("/.well-known/oauth2-redirect.html", oauthRedirect);
    try std.testing.expectEqualStrings("/.well-known/swagger-initializer.js", swaggerInitializerJs);
}

test "constants swagger ui asset paths" {
    try std.testing.expectEqualStrings("/.well-known/swagger-ui-bundle.js", swaggerUIBundle);
    try std.testing.expectEqualStrings("/.well-known/swagger-ui.css", swaggerUICss);
    try std.testing.expectEqualStrings("/.well-known/swagger-ui.js", swaggerUIJs);
}

test "default runtime values" {
    try std.testing.expectEqual(@as(u16, 2), DEFAULT_HTTP_WORKERS);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), DEFAULT_HTTP_MAX_BODY_SIZE_BYTES);
    try std.testing.expectEqual(@as(u16, 8), DEFAULT_HTTP_LARGE_BUFFER_COUNT);
    try std.testing.expectEqual(@as(u16, 32), DEFAULT_HTTP_THREAD_POOL_COUNT);
    try std.testing.expectEqual(@as(u32, 30000), DEFAULT_REQUEST_TIMEOUT_MS);
    try std.testing.expectEqual(@as(u32, 60), DEFAULT_KEEPALIVE_TIMEOUT_MS);
    try std.testing.expectEqual(@as(u64, 100), DEFAULT_RATE_LIMIT_MAX);
    try std.testing.expectEqual(@as(i64, 60_000), DEFAULT_RATE_LIMIT_WINDOW_MS);
    try std.testing.expectEqual(@as(u32, 1024), DEFAULT_INBOUND_MAX_CONCURRENT);
    try std.testing.expectEqual(@as(u32, 10), DEFAULT_PG_POOL_SIZE);
    try std.testing.expectEqual(@as(u32, 10_000), DEFAULT_PG_POOL_ACQUIRE_TIMEOUT_MS);
    try std.testing.expectEqual(@as(u32, 5000), DEFAULT_NATS_MAX_PULL_WAIT_MS);
    try std.testing.expectEqual(@as(u32, 30000), DEFAULT_STATEMENT_TIMEOUT_MS);
    try std.testing.expectEqual(@as(usize, 8), DEFAULT_FRAMEWORK_MEM_SIZE);
    try std.testing.expectEqual(@as(u64, 30), DEFAULT_REMOTE_LOG_REFRESH_INTERVAL_S);
    try std.testing.expectEqual(@as(u32, 3000), DEFAULT_HEALTH_CHECK_TIMEOUT_MS);
    try std.testing.expectEqual(@as(i64, 100), DEFAULT_SERVICE_RETRY_BASE_MS);
    try std.testing.expectEqual(@as(u32, 5), DEFAULT_CB_FAILURE_THRESHOLD);
    try std.testing.expectEqual(@as(u64, 30_000), DEFAULT_CB_COOLDOWN_MS);
    try std.testing.expectEqual(@as(u32, 1), DEFAULT_CB_HALF_OPEN_TRIALS);
    try std.testing.expectEqual(@as(u32, 3), DEFAULT_PUBSUB_MAX_ATTEMPTS);
    try std.testing.expectEqual(@as(i64, 500), DEFAULT_PUBSUB_BACKOFF_MS);
    try std.testing.expectEqual(@as(u32, 60_000), DEFAULT_KAFKA_FLUSH_MS);
    try std.testing.expectEqual(@as(u32, 100), DEFAULT_KAFKA_BATCH_SIZE);
    try std.testing.expectEqual(@as(usize, 100 * 1024 * 1024), DEFAULT_FILESTORE_MAX_BYTES_LOCAL);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), DEFAULT_FILESTORE_MAX_BYTES_S3);
    try std.testing.expectEqual(@as(usize, 100 * 1024 * 1024), DEFAULT_REQUEST_BODY_LIMIT_BYTES);
}
