const std = @import("std");

pub const APP_ENVIRONMENT = "APP_ENV";
pub const APP_NAME = "APP_NAME";
pub const APP_VERSION = "APP_VERSION";

pub const METRICZ_PORT: u16 = 2121;
pub const HTTP_PORT: u16 = 8080;

pub const WELL_KNOWN = "./well-known/";
pub const LIVE_PATH = "/.well-known/live";
pub const HEALTH_PATH = "/.well-known/health";
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
