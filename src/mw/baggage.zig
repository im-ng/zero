const std = @import("std");

pub const Baggage = @This();

/// Hard cap on the number of baggage members a single header may carry. Without
/// this a hostile or buggy upstream could pin unbounded memory per request; the
/// overflow members are silently dropped rather than stored.
pub const MAX_ENTRIES: usize = 64;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// W3C Baggage (https://w3c.github.io/baggage/): a flat set of `key=value`
/// members carried on the `baggage` header and propagated across services. We
/// keep the parsed form so handlers can read/write members before the outbound
/// client re-serializes them onto downstream calls.
allocator: std.mem.Allocator = undefined,
entries: std.ArrayList(Entry) = .empty,

pub fn init(allocator: std.mem.Allocator) Baggage {
    return .{ .allocator = allocator, .entries = .empty };
}

pub fn deinit(self: *Baggage) void {
    for (self.entries.items) |e| {
        self.allocator.free(e.key);
        self.allocator.free(e.value);
    }
    self.entries.deinit(self.allocator);
}

/// Parse a `baggage` header value into structured members. Each member is
/// `key=value`, optionally followed by `;property=value` metadata, which we
/// drop. Members are comma-separated; surrounding whitespace is tolerated.
pub fn parse(allocator: std.mem.Allocator, header: []const u8) Baggage {
    var b = Baggage.init(allocator);
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |member| {
        const trimmed = std.mem.trim(u8, member, " \t\r\n");
        if (trimmed.len == 0) continue;
        // Properties begin at the first ';' and are not part of the value.
        const member_end = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const kv = trimmed[0..member_end];
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = std.mem.trim(u8, kv[0..eq], " \t");
        const value = std.mem.trim(u8, kv[eq + 1 ..], " \t\"");
        if (key.len == 0) continue;
        if (b.entries.items.len >= MAX_ENTRIES) break;
        b.entries.append(allocator, .{
            .key = allocator.dupe(u8, key) catch continue,
            .value = allocator.dupe(u8, value) catch continue,
        }) catch continue;
    }
    return b;
}

/// Look up a member by key (first match wins, as in the spec).
pub fn get(self: *const Baggage, key: []const u8) ?[]const u8 {
    for (self.entries.items) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

/// Set or replace a member. Bounded by `MAX_ENTRIES`; replacing an existing key
/// never grows the set, so a full bag still allows updates.
pub fn set(self: *Baggage, key: []const u8, value: []const u8) !void {
    for (self.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            self.allocator.free(e.value);
            e.value = try self.allocator.dupe(u8, value);
            return;
        }
    }
    if (self.entries.items.len >= MAX_ENTRIES) return error.BaggageFull;
    try self.entries.append(self.allocator, .{
        .key = try self.allocator.dupe(u8, key),
        .value = try self.allocator.dupe(u8, value),
    });
}

/// Serialize back into a `baggage` header value, writing into `buf`. Returns the
/// slice of `buf` used, or `null` when it would overflow. No allocation, so the
/// buffer must outlive the header (an arena or request-scoped scratch is fine).
pub fn format(self: *const Baggage, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (self.entries.items, 0..) |e, i| {
        if (i > 0) {
            if (n + 1 > buf.len) return null;
            buf[n] = ',';
            n += 1;
        }
        if (n + e.key.len + 1 + e.value.len > buf.len) return null;
        @memcpy(buf[n..][0..e.key.len], e.key);
        n += e.key.len;
        buf[n] = '=';
        n += 1;
        @memcpy(buf[n..][0..e.value.len], e.value);
        n += e.value.len;
    }
    return buf[0..n];
}

pub fn count(self: *const Baggage) usize {
    return self.entries.items.len;
}

// ===================== Tests =====================

test "baggage parse, get, set, format round-trip" {
    const alloc = std.testing.allocator;
    var b = Baggage.init(alloc);
    defer b.deinit();

    // Comma-separated members with whitespace and dropped ;properties.
    var parsed = Baggage.parse(alloc, "userId=alice, tenant = acme ; ttl=60 , trace = \"x\"");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.count());
    try std.testing.expectEqualSlices(u8, "alice", parsed.get("userId").?);
    try std.testing.expectEqualSlices(u8, "acme", parsed.get("tenant").?);
    try std.testing.expectEqualSlices(u8, "x", parsed.get("trace").?);

    // set replaces an existing key without growing the set.
    try parsed.set("tenant", "globex");
    try std.testing.expectEqual(@as(usize, 3), parsed.count());
    try std.testing.expectEqualSlices(u8, "globex", parsed.get("tenant").?);

    // format re-serializes the members.
    var buf: [256]u8 = undefined;
    const out = parsed.format(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "userId=alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tenant=globex") != null);
}

test "baggage parse tolerates empty and malformed input" {
    const alloc = std.testing.allocator;
    var empty = Baggage.parse(alloc, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.count());

    // A member with no '=' is skipped; a well-formed one still parses.
    var partial = Baggage.parse(alloc, "garbage, key=val");
    defer partial.deinit();
    try std.testing.expectEqual(@as(usize, 1), partial.count());
    try std.testing.expectEqualSlices(u8, "val", partial.get("key").?);
}
