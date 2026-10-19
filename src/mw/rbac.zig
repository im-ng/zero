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
/// When `deny` is true the rule explicitly forbids `role` on `method`/`path`;
/// a deny wins over any allow (audit #33).
pub const Permission = struct {
    role: []const u8,
    method: []const u8,
    path: []const u8,
    exempt: bool = false,
    deny: bool = false,
};

/// Role-based access control registry. Routes with no matching rule are
/// public; a route with at least one rule requires the caller's role to match
/// one of them.
pub const RBAC = struct {
    allocator: std.mem.Allocator,
    permissions: std.array_list.Managed(Permission),
    /// When true, any route with no matching rule is denied instead of public
    /// (audit #33). Defaults to false to preserve the legacy public-by-default
    /// contract; operators opting into zero-trust set this.
    default_deny: bool = false,

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

    /// Adds an explicit deny: `role` is forbidden on `method`/`path` even if an
    /// allow rule would otherwise grant it. Deny takes precedence (audit #33).
    pub fn addDeny(self: *RBAC, role: []const u8, method: []const u8, path: []const u8) !void {
        try self.permissions.append(.{ .role = role, .method = method, .path = path, .deny = true });
    }

    /// `true` if `role` may access (method, path). Method may be `*` and path
    /// may end with `*` as a prefix wildcard. An explicit deny for the role wins
    /// over any allow. A route with no rule is public unless `default_deny` is set.
    pub fn allows(self: *const RBAC, role: []const u8, method: []const u8, path: []const u8) bool {
        var protected_route = false;
        var explicitly_allowed = false;
        for (self.permissions.items) |p| {
            if (!pathMatches(p.path, path)) continue;
            if (p.deny) {
                // An explicit deny for this role/method/path overrides any allow.
                if (methodMatches(p.method, method) and std.mem.eql(u8, p.role, role)) {
                    return false;
                }
                continue;
            }
            if (p.exempt) {
                // an exempt rule claims the whole path: only its listed methods
                // bypass RBAC; other methods stay protected (require a role rule).
                if (methodMatches(p.method, method)) return true;
                protected_route = true;
                continue;
            }
            if (methodMatches(p.method, method)) {
                protected_route = true;
                if (std.mem.eql(u8, p.role, role)) explicitly_allowed = true;
            }
        }
        if (explicitly_allowed) return true;
        if (protected_route) return false;
        // No rule referenced this path: public unless zero-trust mode is on (#33).
        return !self.default_deny;
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
                    if (item != .object) {
                        return error.InvalidRbacConfig;
                    }

                    if (item.object.get("permissions") == null) {
                        return error.InvalidRbacConfig;
                    }

                    try self.addEndpointRule(allocator, item);
                }
            },
            .object => |obj| {
                if (obj.get("permissions") == null) {
                    return error.InvalidRbacConfig;
                }

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
        if (perms != .array) {
            return error.InvalidRbacConfig;
        }

        const endpoint = obj.get("endpoint") orelse return error.InvalidRbacConfig;
        if (endpoint != .string) {
            return error.InvalidRbacConfig;
        }

        const methods = obj.get("methods") orelse return error.InvalidRbacConfig;
        if (methods != .array) {
            return error.InvalidRbacConfig;
        }

        var exempt = false;
        if (obj.get("exempt")) |e| {
            if (e != .bool) {
                return error.InvalidRbacConfig;
            }

            exempt = e.bool;
        }

        // Optional `deny` flag: the generated rules explicitly forbid the role
        // (audit #33). `deny` and `exempt` are mutually exclusive per rule.
        var deny = false;
        if (obj.get("deny")) |d| {
            if (d != .bool) {
                return error.InvalidRbacConfig;
            }

            deny = d.bool;
        }

        for (perms.array.items) |p| {
            if (p != .string) {
                return error.InvalidRbacConfig;
            }

            for (methods.array.items) |m| {
                if (m != .string) {
                    return error.InvalidRbacConfig;
                }

                const role = try allocator.dupe(u8, p.string);
                const method = try allocator.dupe(u8, m.string);
                const path = try allocator.dupe(u8, endpoint.string);
                if (deny) {
                    try self.addDeny(role, method, path);
                } else if (exempt) {
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
    if (std.mem.eql(u8, rule_method, "*")) {
        return true;
    }

    return std.ascii.eqlIgnoreCase(rule_method, req_method);
}

fn pathMatches(rule_path: []const u8, req_path: []const u8) bool {
    // Collapse a single trailing slash on both sides so `/api/users` and
    // `/api/users/` resolve to the same rule (audit #33). A trailing slash was
    // a trivial bypass of exact-match rules.
    const rp = stripTrailingSlash(rule_path);
    const rq = stripTrailingSlash(req_path);
    if (std.mem.eql(u8, rp, rq)) {
        return true;
    }

    if (std.mem.endsWith(u8, rp, "*")) {
        const prefix = rp[0 .. rp.len - 1];
        return std.mem.startsWith(u8, rq, prefix);
    }

    return false;
}

/// Strip one trailing slash (the root `/` is preserved) so trailing-slash
/// variants of a path match the same rule.
fn stripTrailingSlash(p: []const u8) []const u8 {
    if (p.len > 1 and std.mem.endsWith(u8, p, "/")) {
        return p[0 .. p.len - 1];
    }
    return p;
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
        self.auditDenial(req, "no-role");
        res.setStatus(.forbidden);
        return;
    };

    if (self.registry.?.allows(role, @tagName(req.method), req.url.path)) {
        return executor.next();
    }

    self.auditDenial(req, role);
    res.setStatus(.forbidden);
}

/// Emits an audit-log line for a denied request (audit #33). The message is
/// allocated, logged synchronously, then freed — logging does not retain it.
fn auditDenial(self: *const rbac, req: *httpz.Request, role: []const u8) void {
    const msg = std.fmt.allocPrint(self.allocator, "RBAC deny: role={s} {s} {s}", .{
        role,
        @tagName(req.method),
        req.url.path,
    }) catch return;
    self.container.?.log.warn(msg);
    self.allocator.free(msg);
}

/// Extracts the role from the verified JWT `role` claim. Returns null when
/// there is no auth header or the token carries no role (e.g. Basic/API key).
fn roleFor(self: *const rbac, req: *httpz.Request) ?[]const u8 {
    const header = req.header(constants.AUTH_HEADER) orelse return null;

    const claims = self.container.?.authProvider.retrieveClaims(req.arena, header) catch return null;
    if (claims.role.len == 0) {
        return null;
    }

    return claims.role;
}

fn isWellKnownPath(_: *const rbac, req: *httpz.Request) bool {
    if (std.mem.eql(u8, req.url.path, constants.HEALTH_PATH)) {
        return true;
    }

    if (std.mem.eql(u8, req.url.path, constants.LIVE_PATH)) {
        return true;
    }

    if (std.mem.startsWith(u8, req.url.path, constants.WELL_KNOWN)) {
        return true;
    }

    if (std.mem.eql(u8, req.url.path, constants.METRICS_PATH)) {
        return true;
    }

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

test "rbac explicit deny overrides allow (audit #33)" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.add("admin", "GET", "/api/secret");
    try rb.addDeny("admin", "GET", "/api/secret");
    // deny wins even though an allow rule exists
    try std.testing.expect(!rb.allows("admin", "GET", "/api/secret"));
    // a role with no allow is still denied
    try std.testing.expect(!rb.allows("user", "GET", "/api/secret"));
}

test "rbac default_deny blocks unruled routes (audit #33)" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    rb.default_deny = true;
    // no rule references this path -> denied under zero-trust mode
    try std.testing.expect(!rb.allows("admin", "GET", "/never/configured"));
    // an explicit allow still works
    try rb.add("admin", "GET", "/api/ok");
    try std.testing.expect(rb.allows("admin", "GET", "/api/ok"));
    // default-open contract is preserved when default_deny is false
    var open = RBAC.init(std.testing.allocator);
    defer open.deinit();
    try std.testing.expect(open.allows("admin", "GET", "/never/configured"));
}

test "rbac trailing slash cannot bypass exact rule (audit #33)" {
    var rb = RBAC.init(std.testing.allocator);
    defer rb.deinit();
    try rb.add("admin", "GET", "/api/users");
    // exact and trailing-slash variants resolve to the same rule
    try std.testing.expect(rb.allows("admin", "GET", "/api/users"));
    try std.testing.expect(rb.allows("admin", "GET", "/api/users/"));
    try std.testing.expect(!rb.allows("user", "GET", "/api/users/"));
    // prefix wildcard still matches deeper paths with or without trailing slash
    var rb2 = RBAC.init(std.testing.allocator);
    defer rb2.deinit();
    try rb2.add("admin", "GET", "/api/*");
    try std.testing.expect(rb2.allows("admin", "GET", "/api/users/"));
    try std.testing.expect(rb2.allows("admin", "GET", "/api/users"));
}

test "rbac fromJson deny flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try rb.fromJson(arena.allocator(),
        \\{"permissions":["EVIL"],"endpoint":"/api/*","methods":["GET"],"deny":true}
    );
    // deny rule forbids the role even on the wildcard path
    try std.testing.expect(!rb.allows("EVIL", "GET", "/api/x"));
    // other roles remain allowed (no allow rule, so public by default)
    try std.testing.expect(rb.allows("GOOD", "GET", "/api/x"));
}
