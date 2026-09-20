const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const ClientError = zero.Error.ClientError;
const Client = zero.client;
const jwtClaims = zero.jwtClaims;
const utils = zero.utils;

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

pub const std_options: std.Options = .{
    .logFn = zero.logger.custom,
};

pub fn main(init: std.process.Init) !void {

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    _ = gpa.detectLeaks();

    const app: *App = try App.new(allocator, init.io, init.environ_map);

    try app.get("/basic", basicResponse);

    try app.get("/apikey", apiKeyResponse);

    try app.get("/oauth", oauthResponse);

    try app.get("/json", jsonResponse);

    // RBAC-protected endpoints demonstrating the endpoint-rule format.
    //   GET  /api/resource -> requires the USER role
    //   POST /api/resource -> requires the ADMIN role
    // Roles come from the `role` claim of an authenticated request (OAuth/JWT).
    try app.get("/api/resource", getResource);
    try app.post("/api/resource", postResource);

    // Load RBAC rules from the RBAC_CONFIG env var (endpoint-rule JSON only).
    // A no-op when RBAC_CONFIG is empty, so the rest of the app stays public.
    try app.rbacFromEnv();

    try app.run();
}

fn getResource(ctx: *Context) !void {
    try ctx.json(.{ .msg = "resource read (USER)" });
}

fn postResource(ctx: *Context) !void {
    try ctx.json(.{ .msg = "resource written (ADMIN)" });
}

fn jsonResponse(ctx: *Context) !void {
    try ctx.json(.{ .msg = "all good!" });
}

pub fn basicResponse(ctx: *Context) !void {
    // retrieve the claims
    const claims = try ctx.getUsername();
    try ctx.json(claims.?);
}

pub fn apiKeyResponse(ctx: *Context) !void {
    // retrieve the claims
    const claims = try ctx.getAuthKey();
    try ctx.json(.{ .key = claims, .msg = "all good!" });
}

pub fn oauthResponse(ctx: *Context) !void {
    // retrieve the claims
    const claims = try ctx.getAuthClaims();
    try ctx.json(claims);
}

// pub fn keysResponse(ctx: *Context) !void {
//     const service: ?*Client = ctx.getService("zero-jwks-service");
//     if (service == null) {
//         ctx.err("zero jwks service is not available");
//     }
//     const http = service.?;

//     var req = try http.client.allocRequest(ctx.allocator, http.url.?);
//     defer req.deinit();

//     req.method = std.http.Method.GET;

//     var res = try req.getResponse(.{});

//     switch (res.status) { //expand more
//         404 => {
//             return ClientError.EntityNotFound;
//         },
//         500...600 => {
//             return ClientError.ServiceNotReachable;
//         },
//         else => {
//             // do nothing
//         },
//     }

//     const parsed = try res.json(publicKeys, ctx.allocator, .{});
//     defer parsed.deinit();

//     ctx.info("oatuh keys refreshed");

//     ctx.response.setStatus(.ok);
//     try ctx.response.json(parsed.value, .{});
// }
