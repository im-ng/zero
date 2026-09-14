const std = @import("std");
const root = @import("../zero.zig");

const rbac = @This();
const httpz = root.httpz;
const constants = root.constants;

allocator: std.mem.Allocator,
container: ?*root.container = undefined,
registry: ?*RBAC = undefined,

/// A single allow-rule: `role` may call `method` on `path`.
pub const Permission = struct {
    role: []const u8,
    method: []const u8,
    path: []const u8,
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

    /// `true` if `role` may access (method, path). Method may be `*` and path
    /// may end with `*` as a prefix wildcard. A route with no rule is allowed.
    pub fn allows(self: *const RBAC, role: []const u8, method: []const u8, path: []const u8) bool {
        var protected = false;
        for (self.permissions.items) |p| {
            if (methodMatches(p.method, method) and pathMatches(p.path, path)) {
                protected = true;
                if (std.mem.eql(u8, p.role, role)) {
                    return true;
                }
            }
        }
        return !protected;
    }

    pub fn deinit(self: *RBAC) void {
        self.permissions.deinit();
    }

    /// Parses RBAC rules from a JSON string. Two shapes are accepted:
    ///   - an array of `{"role": "...", "method": "...", "path": "..."}` objects
    ///   - an object mapping role → `["METHOD:/path", "METHOD:/path", ...]`
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
                    const obj = item.object;
                    const role = obj.get("role") orelse return error.InvalidRbacConfig;
                    const method = obj.get("method") orelse return error.InvalidRbacConfig;
                    const path = obj.get("path") orelse return error.InvalidRbacConfig;
                    if (role != .string or method != .string or path != .string) {
                        return error.InvalidRbacConfig;
                    }
                    try self.add(
                        try allocator.dupe(u8, role.string),
                        try allocator.dupe(u8, method.string),
                        try allocator.dupe(u8, path.string),
                    );
                }
            },
            .object => |roles| {
                var it = roles.iterator();
                while (it.next()) |entry| {
                    const role = entry.key_ptr.*;
                    const rules = entry.value_ptr.*;
                    if (rules != .array) return error.InvalidRbacConfig;
                    for (rules.array.items) |rule| {
                        if (rule != .string) return error.InvalidRbacConfig;
                        var mp = std.mem.splitScalar(u8, rule.string, ':');
                        const m = mp.next() orelse return error.InvalidRbacConfig;
                        const p = mp.next() orelse return error.InvalidRbacConfig;
                        try self.add(
                            try allocator.dupe(u8, role),
                            try allocator.dupe(u8, std.mem.trim(u8, m, " ")),
                            try allocator.dupe(u8, std.mem.trim(u8, p, " ")),
                        );
                    }
                }
            },
            else => return error.InvalidRbacConfig,
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

test "rbac fromJson array form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try rb.fromJson(arena.allocator(),
        \\[{"role":"ADMIN","method":"*","path":"/api/*"},{"role":"USER","method":"GET","path":"/api/resource"}]
    );
    try std.testing.expect(rb.allows("ADMIN", "POST", "/api/users"));
    try std.testing.expect(!rb.allows("USER", "POST", "/api/users"));
    try std.testing.expect(rb.allows("USER", "GET", "/api/resource"));
}

test "rbac fromJson object form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try rb.fromJson(arena.allocator(),
        \\{"ADMIN":["GET:/api/*","POST:/api/*"],"USER":["GET:/api/resource"]}
    );
    try std.testing.expect(rb.allows("ADMIN", "GET", "/api/x"));
    try std.testing.expect(!rb.allows("USER", "GET", "/api/x"));
}

test "rbac fromJson invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rb = RBAC.init(arena.allocator());
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(), "not json"));
    try std.testing.expectError(RbacError.InvalidRbacConfig, rb.fromJson(arena.allocator(), "[1,2,3]"));
}
