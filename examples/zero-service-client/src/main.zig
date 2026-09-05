const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;
const ClientError = zero.Error.ClientError;

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub const publicKey = struct {
    kid: []const u8,
    kty: []const u8,
    use: []const u8,
    n: []const u8,
    e: []const u8,
    alg: []const u8,
};

pub const publicKeys = struct {
    keys: []publicKey,
};

pub fn main(init: std.process.Init) !void {
    utils.setIo(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app = try App.new(allocator, init.environ_map);

    // Per-service outbound config: auth + circuit breaker. Explicit values here
    // override any SERVICE_AUTHSERVICE_* env defaults resolved by addHttpService.
    var svc_opts: zero.client.ServiceOptions = .{};
    svc_opts.circuitBreaker = .{ .failure_threshold = 5, .cooldown_ms = 30_000 };

    const svc_key = app.config.getOrDefault("AUTH_API_KEY", "");
    if (svc_key.len > 0) {
        svc_opts.auth = .{
            .mode = .apiKey,
            .apiKey = .{ .key = svc_key },
        };
    }

    const svc_token_url = app.config.getOrDefault("AUTH_OAUTH_TOKEN_URL", "");
    if (svc_token_url.len > 0) {
        svc_opts.auth = .{
            .mode = .oauth,
            .oauth = .{
                .tokenUrl = svc_token_url,
                .clientId = app.config.getOrDefault("AUTH_OAUTH_CLIENT_ID", ""),
                .clientSecret = app.config.getOrDefault("AUTH_OAUTH_CLIENT_SECRET", ""),
                .scope = if (app.config.getOrDefault("AUTH_OAUTH_SCOPE", "").len > 0)
                    app.config.getOrDefault("AUTH_OAUTH_SCOPE", "")
                else
                    null,
            },
        };
    }

    try app.addHttpService("auth-service", app.config.get("SERVICE_URL"), svc_opts);

    try app.get("/keys", serviceStatus);

    try app.run();
}

fn serviceStatus(ctx: *Context) !void {
    const service = ctx.getService("auth-service");

    if (service) |basicSvc| {
        const response = try basicSvc.get(ctx, publicKeys, "/keys", null, null);
        try ctx.json(response);
    }
}
