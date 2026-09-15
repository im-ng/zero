const std = @import("std");
const root = @import("../zero.zig");

const rbac = @This();
const httpz = root.httpz;
const constants = root.constants;

allocator: std.mem.Allocator,
container: ?*root.container = undefined,
registry: ?*RBAC = undefined,

/// A single allow-rule: `role` may call `method` on `path`. When `exempt` is
/// true the rule bypasses RBAC entirely for its `method`/`path` (see `addExempt`).
pub const Permission = struct {
    role: []const u8,
    method: []const u8,
    path: []const u8,
    exempt: bool = false,
};

/// Role-based access control registry. Routes with no matching rule are
/// public; a route with at least one rule requires the caller's role to match
/// one of them.
pub const RBAC = struct {
    allocator: std.mem.Allocator,
    permissions: std.array_list.Managed(Permission),

    pub fn init(allocator: std.mem.Allocator) RBAC {
        return .{
            .allocator = allocator,
            .permissions = std.array_list.Managed(Permission).init(allocator),
        };
    }

    pub fn add(self: *RBAC, role: []const u8, method: []const u8, path: []const u8) !void {
        try self.permissions.append(.{ .role = role, .method = method, .path = path });
    }

    /// Adds an exempt rule: `method` on `path` bypasses RBAC for any role. Used
    /// by the `endpoint`/`methods`/`exempt` config shape.
    pub fn addExempt(self: *RBAC, role: []const u8, method: []const u8, path: []const u8) !void {
        try self.permissions.append(.{ .role = role, .method = method, .path = path, .exempt = true });
    }

    /// `true` if `role` may access (method, path). Method may be `*` and path
    /// may end with `*` as a prefix wildcard. A route with no rule is allowed.
    pub fn allows(self: *const RBAC, role: []const u8, method: []const u8, path: []const u8) bool {
        var protected = false;
        for (self.permissions.items) |p| {
            if (!pathMatches(p.path, path)) continue;
            if (p.exempt) {
                // an exempt rule claims the whole path: only its listed methods
                // bypass RBAC; other methods stay protected (require a role rule).
                if (methodMatches(p.method, method)) return true;
                protected = true;
                continue;
            }
            if (methodMatches(p.method, method)) {
                protected = true;
                if (std.mem.eql(u8, p.role, role)) return true;
            }
        }
        return !protected;
    }

    pub fn deinit(self: *RBAC) void {
        self.permissions.deinit();
    }

    /// Parses RBAC rules from a JSON string in the endpoint-rule format only:
    ///   {"permissions":["ROLE",...], "endpoint":"...", "methods":["GET",...], "exempt": bool}
    /// Accepted as a single object or an array of such objects. `exempt`
    /// (default false) bypasses RBAC for the listed methods only. Any other
    /// shape (e.g. the legacy `{role,method,path}` form) is rejected.
    /// String values are copied into `allocator` so the parsed document may be freed.
    pub fn fromJson(self: *RBAC, allocator: std.mem.Allocator, json_config: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_config, .{}) catch {
            return error.InvalidRbacConfig;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .array => |rules| {
                for (rules.items) |item| {
                    if (item != .object) return error.InvalidRbacConfig;
                    if (item.object.get("permissions") == null) return error.InvalidRbacConfig;
                    try self.addEndpointRule(allocator, item);
                }
            },
            .object => |obj| {
                if (obj.get("permissions") == null) return error.InvalidRbacConfig;
                try self.addEndpointRule(allocator, parsed.value);
            },
            else => return error.InvalidRbacConfig,
        }
    }

    /// Parses an endpoint-rule object of the form
    ///   {"permissions":[...], "endpoint":"...", "methods":[...], "exempt": bool}
    /// and registers one rule per (permission × method). Honors the optional
    /// `exempt` flag (defaults to false).
    fn addEndpointRule(self: *RBAC, allocator: std.mem.Allocator, item: std.json.Value) !void {
        const obj = item.object;
        const perms = obj.get("permissions") orelse return error.InvalidRbacConfig;
        if (perms != .array) return error.InvalidRbacConfig;
        const endpoint = obj.get("endpoint") orelse return error.InvalidRbacConfig;
        if (endpoint != .string) return error.InvalidRbacConfig;
        const methods = obj.get("methods") orelse return error.InvalidRbacConfig;
        if (methods != .array) return error.InvalidRbacConfig;

        var exempt = false;
        if (obj.get("exempt")) |e| {
            if (e != .bool) return error.InvalidRbacConfig;
            exempt = e.bool;
        }

        for (perms.array.items) |p| {
            if (p != .string) return error.InvalidRbacConfig;
            for (methods.array.items) |m| {
                if (m != .string) return error.InvalidRbacConfig;
                const role = try allocator.dupe(u8, p.string);
                const method = try allocator.dupe(u8, m.string);
                const path = try allocator.dupe(u8, endpoint.string);
                if (exempt) {
                    try self.addExempt(role, method, path);
                } else {
                    try self.add(role, method, path);
                }
            }
        }
    }
};

pub const RbacError = error{
    InvalidRbacConfig,
};

fn methodMatches(rule_method: []const u8, req_method: []const u8) bool {
    if (std.mem.eql(u8, rule_method, "*")) return true;
    return std.ascii.eqlIgnoreCase(rule_method, req_method);
}

fn pathMatches(rule_path: []const u8, req_path: []const u8) bool {
    if (std.mem.eql(u8, rule_path, req_path)) return true;
    if (std.mem.endsWith(u8, rule_path, "*")) {
        const prefix = rule_path[0 .. rule_path.len - 1];
        return std.mem.startsWith(u8, req_path, prefix);
    }
    return false;
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    container: *root.container,
    rbac: ?*RBAC,
};

pub fn init(c: Config) !rbac {
    return .{
        .allocator = c.allocator,
        .container = c.container,
        .registry = c.rbac,
    };
}

pub fn execute(self: *const rbac, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (self.registry == null) {
        return executor.next();
    }

    if (self.isWellKnownPath(req)) {
        return executor.next();
    }

    const role = self.roleFor(req) orelse {
        res.setStatus(.forbidden);
        return;
    };

    if (self.registry.?.allows(role, @tagName(req.method), req.url.path)) {
        return executor.next();
    }

    res.setStatus(.forbidden);
}

/// Extracts the role from the verified JWT `role` claim. Returns null when
/// there is no auth header or the token carries no role (e.g. Basic/API key).
fn roleFor(self: *const rbac, req: *httpz.Request) ?[]const u8 {
    const header = req.header(constants.AUTH_HEADER) orelse return null;
    const claims = self.container.?.authProvider.retrieveClaims(req.arena, header) catch return null;
    if (claims.role.len == 0) return null;
    return claims.role;
}

fn isWellKnownPath(_: *const rbac, req: *httpz.Request) bool {
    if (std.mem.eql(u8, req.url.path, constants.HEALTH_PATH)) return true;
    if (std.mem.eql(u8, req.url.path, constants.LIVE_PATH)) return true;
    if (std.mem.startsWith(u8, req.url.path, constants.WELL_KNOWN)) return true;
    if (std.mem.eql(u8, req.url.path, constants.METRICS_PATH)) return true;
    return false;
}


// ===================== Tests =====================


test "rbac allows public route with no rule" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try std.testing.expect(rb.allows("admin", "GET", "/public"));
}

test "rbac allows when role matches rule" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.add("admin", "GET", "/api/users");
    try std.testing.expect(rb.allows("admin", "GET", "/api/users"));
    try std.testing.expect(!rb.allows("user", "GET", "/api/users"));
}

test "rbac method wildcard and case-insensitive" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.add("admin", "*", "/api/users");
    try std.testing.expect(rb.allows("admin", "POST", "/api/users"));
    try std.testing.expect(rb.allows("admin", "delete", "/api/users"));
    try std.testing.expect(!rb.allows("user", "GET", "/api/users"));
}

test "rbac path prefix wildcard" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.add("admin", "GET", "/api/*");
    try std.testing.expect(rb.allows("admin", "GET", "/api/users/1"));
    try std.testing.expect(rb.allows("admin", "GET", "/api"));
    // routes matching no rule are public
    try std.testing.expect(rb.allows("admin", "GET", "/web/users"));
    try std.testing.expect(!rb.allows("user", "GET", "/api/users"));
}

test "rbac fromJson rejects legacy shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    // legacy {role, method, path} array form is no longer accepted
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(),
        \\[{"role":"ADMIN","method":"*","path":"/api/*"}]
    ));
    // legacy role -> [METHOD:/path] object form is no longer accepted
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(),
        \\{"ADMIN":["GET:/api/*"]}
    ));
    // endpoint-rule without a `permissions` key is rejected
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(),
        \\{"endpoint":"/api/*","methods":["GET"]}
    ));
}

test "rbac fromJson invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(), "not json"));
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(), "[1,2,3]"));
}

test "rbac fromJson endpoint-rule array form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    // permissions: ADMIN + USER; methods: GET + POST; endpoint: /api/admin/*
    try rb.fromJson(arena.allocator(),
        \\[{"permissions":["ADMIN","USER"],"endpoint":"/api/admin/*","methods":["GET","POST"],"exempt":true}]
    );
    // listed methods bypass auth for any role (exempt)
    try std.testing.expect(rb.allows("ADMIN", "GET", "/api/admin/x"));
    try std.testing.expect(rb.allows("GUEST", "POST", "/api/admin/x"));
    // exempt only for listed methods: an unlisted method stays protected
    // (no role rule grants it, so it is denied)
    try std.testing.expect(!rb.allows("USER", "DELETE", "/api/admin/x"));
}

test "rbac fromJson endpoint-rule non-exempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try rb.fromJson(arena.allocator(),
        \\{"permissions":["USER"],"endpoint":"/api/resource","methods":["GET"]}
    );
    try std.testing.expect(rb.allows("USER", "GET", "/api/resource"));
    try std.testing.expect(!rb.allows("ADMIN", "GET", "/api/resource"));
    // a method not in `methods` has no protecting rule -> public (matches legacy
    // single-method rules, where only the listed method is restricted)
    try std.testing.expect(rb.allows("ANONYMOUS", "POST", "/api/resource"));
}

test "rbac exempt bypasses role check" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.addExempt("ADMIN", "GET", "/healthz");
    // any role passes on an exempt method/path
    try std.testing.expect(rb.allows("anonymous", "GET", "/healthz"));
    // non-exempt method on same path still requires a role rule
    try std.testing.expect(!rb.allows("anonymous", "POST", "/healthz"));
}

