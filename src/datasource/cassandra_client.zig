const std = @import("std");

const linux = std.os.linux;

/// Linux `struct sockaddr_in` layout (family, port, addr, padding).
const SockAddrIn = extern struct {
    family: u16 = linux.AF.INET,
    port: u16,
    addr: u32,
    zero: [8]u8 = [_]u8{0} ** 8,
};

const List = std.array_list.AlignedManaged(u8, null);

/// Minimal Apache Cassandra native protocol v4 client (binary CQL), implemented
/// directly on `std.posix` so it has no external dependencies. Covers the subset
/// needed by the `NoSQL` interface: STARTUP/AUTH handshake + QUERY (no bound
/// values, consistency ONE) + Rows result parsing. Compression is not negotiated.
pub const Consistency = enum(u16) {
    any = 0x0000,
    one = 0x0001,
    two = 0x0002,
    three = 0x0003,
    quorum = 0x0004,
    all = 0x0005,
    local_quorum = 0x0006,
    each_quorum = 0x0007,
    local_one = 0x000A,
};

const Opcode = struct {
    const startup: u8 = 0x01;
    const ready: u8 = 0x02;
    const authenticate: u8 = 0x03;
    const options: u8 = 0x05;
    const supported: u8 = 0x06;
    const query: u8 = 0x07;
    const result: u8 = 0x08;
    const error_code: u8 = 0x00;
    const auth_response: u8 = 0x0F;
    const auth_success: u8 = 0x10;
};

/// A single decoded result column value. `data` is owned (freed by `QueryResult.deinit`).
pub const Cell = struct {
    type_id: i32,
    data: ?[]u8,
};

/// A result column descriptor.
pub const Column = struct {
    name: []const u8,
    type_id: i32,
};

pub const Row = struct {
    cells: []Cell,
};

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    columns: []Column,
    rows: []Row,

    pub fn deinit(self: *QueryResult) void {
        for (self.columns) |c| {
            self.allocator.free(c.name);
        }
        self.allocator.free(self.columns);
        for (self.rows) |r| {
            for (r.cells) |c| {
                if (c.data) |d| {
                    self.allocator.free(d);
                }
            }
            self.allocator.free(r.cells);
        }
        self.allocator.free(self.rows);
    }

    /// Render the rows as a JSON array of objects, using `alloc` for output.
    pub fn toJson(self: *const QueryResult, alloc: std.mem.Allocator) ![]u8 {
        var buf = List.init(alloc);
        try buf.append('[');
        for (self.rows, 0..) |row, ri| {
            if (ri > 0) {
                try buf.append(',');
            }
            try buf.append('{');
            for (row.cells, self.columns, 0..) |cell, col, ci| {
                if (ci > 0) {
                    try buf.append(',');
                }
                try writeJsonString(&buf, col.name);
                try buf.append(':');
                try writeValue(&buf, alloc, cell);
            }
            try buf.append('}');
        }
        try buf.append(']');
        return buf.toOwnedSlice();
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: ?linux.fd_t = null,
    contact_points: []const u8,
    user: []const u8,
    pass: []const u8,
    /// When set, a `USE` statement is issued right after the auth handshake so
    /// every later statement runs in this keyspace without re-qualifying it.
    keyspace: ?[]const u8 = null,
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *Connection) void {
        while (!self.mutex.tryLock()) {
            // Best-effort: yielding is an optimization while spinning for the lock;
            // if it fails there is nothing to do but retry.
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Connection) void {
        self.mutex.unlock();
    }

    pub fn init(allocator: std.mem.Allocator, contact_points: []const u8, user: []const u8, pass: []const u8, keyspace: ?[]const u8) Connection {
        return .{
            .allocator = allocator,
            .contact_points = contact_points,
            .user = user,
            .pass = pass,
            .keyspace = keyspace,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.fd) |fd| {
            _ = linux.close(fd);
        }
        self.fd = null;
    }

    fn ensureConnected(self: *Connection) !void {
        if (self.fd != null) return;
        var it = std.mem.tokenizeScalar(u8, self.contact_points, ',');
        while (it.next()) |cp| {
            const hostport = std.mem.trim(u8, cp, " ");
            if (try connectOne(hostport)) |fd| {
                self.fd = fd;
                try self.handshake();
                return;
            }
        }
        return error.CassandraConnectionFailed;
    }

    fn connectOne(hostport: []const u8) !?linux.fd_t {
        const sep = std.mem.indexOfScalar(u8, hostport, ':') orelse return null;
        const host = hostport[0..sep];
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, hostport[sep + 1 ..], " "), 10) catch return null;

        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(rc);

        var sa: SockAddrIn = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = parseIpv4(host) catch {
                _ = linux.close(fd);
                return null;
            },
        };

        const rc2 = linux.connect(fd, @ptrCast(&sa), @sizeOf(SockAddrIn));
        if (linux.errno(rc2) != .SUCCESS) {
            _ = linux.close(fd);
            return null;
        }
        return fd;
    }

    fn parseIpv4(host: []const u8) !u32 {
        var octets: [4]u32 = undefined;
        var i: usize = 0;
        var it = std.mem.tokenizeScalar(u8, host, '.');
        while (i < 4) {
            const part = it.next() orelse return error.InvalidIp;
            octets[i] = try std.fmt.parseInt(u32, part, 10);
            if (octets[i] > 255) return error.InvalidIp;
            i += 1;
        }
        if (it.next() != null) return error.InvalidIp;
        const raw = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
        return std.mem.nativeToBig(u32, raw);
    }

    fn handshake(self: *Connection) !void {
        var body = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer body.deinit();
        const entries = [_]struct { k: []const u8, v: []const u8 }{.{
            .k = "CQL_VERSION",
            .v = "3.0.0",
        }};
        try writeStringMap(&body, entries[0..]);
        try self.writeFrame(Opcode.startup, body.items);

        const resp = try self.readFrame();
        defer self.allocator.free(resp.body);
        switch (resp.opcode) {
            Opcode.ready => {},
            Opcode.authenticate => {
                var token = std.array_list.AlignedManaged(u8, null).init(self.allocator);
                defer token.deinit();
                try token.append(0);
                try token.appendSlice(self.user);
                try token.append(0);
                try token.appendSlice(self.pass);

                var fb = std.array_list.AlignedManaged(u8, null).init(self.allocator);
                defer fb.deinit();
                try writeBytes(&fb, token.items);
                try self.writeFrame(Opcode.auth_response, fb.items);

                const resp2 = try self.readFrame();
                defer self.allocator.free(resp2.body);
                if (resp2.opcode != Opcode.ready and resp2.opcode != Opcode.auth_success) {
                    return error.CassandraAuthFailed;
                }
            },
            Opcode.error_code => return error.CassandraStartupError,
            else => return error.CassandraProtocolError,
        }

        // Pin the session to the configured keyspace so callers need not
        // qualify every table reference. This runs inside the connect lock,
        // so it writes/reads frames directly rather than via `query`.
        if (self.keyspace) |ks| {
            const use_cql = try std.fmt.allocPrint(self.allocator, "USE {s}", .{ks});
            defer self.allocator.free(use_cql);
            var use_body = std.array_list.AlignedManaged(u8, null).init(self.allocator);
            defer use_body.deinit();
            try writeLongString(&use_body, use_cql);
            var cf: [3]u8 = undefined;
            std.mem.writeInt(u16, cf[0..2], @intFromEnum(Consistency.one), .big);
            cf[2] = 0x00; // flags: no values
            try use_body.appendSlice(&cf);
            try self.writeFrame(Opcode.query, use_body.items);

            const use_resp = try self.readFrame();
            defer self.allocator.free(use_resp.body);
            if (use_resp.opcode == Opcode.error_code) return error.CassandraQueryError;
            if (use_resp.opcode != Opcode.result) return error.CassandraProtocolError;
        }
    }

    pub fn query(self: *Connection, cql: []const u8) !QueryResult {
        self.lock();
        defer self.unlock();
        try self.ensureConnected();

        var body = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer body.deinit();
        try writeLongString(&body, cql);
        var cf: [3]u8 = undefined;
        std.mem.writeInt(u16, cf[0..2], @intFromEnum(Consistency.one), .big);
        cf[2] = 0x00; // flags: no values
        try body.appendSlice(&cf);
        try self.writeFrame(Opcode.query, body.items);

        const resp = try self.readFrame();
        defer self.allocator.free(resp.body);
        if (resp.opcode == Opcode.error_code) return error.CassandraQueryError;
        if (resp.opcode != Opcode.result) return error.CassandraProtocolError;

        return try parseResult(self.allocator, resp.body);
    }

    fn writeFrame(self: *Connection, opcode: u8, body: []const u8) !void {
        const fd = self.fd.?;
        var header: [9]u8 = undefined;
        header[0] = 0x04; // protocol version 4 (request)
        header[1] = 0x00; // flags
        header[2] = 0x00;
        header[3] = 0x00; // stream id
        header[4] = opcode;
        std.mem.writeInt(u32, header[5..9], @intCast(body.len), .big);
        try writeAll(fd, &header);
        try writeAll(fd, body);
    }

    fn readFrame(self: *Connection) !struct { opcode: u8, body: []u8 } {
        const fd = self.fd.?;
        var header: [9]u8 = undefined;
        try readExact(fd, &header);
        const opcode = header[4];
        const len = std.mem.readInt(u32, header[5..9], .big);
        const body = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(body);
        try readExact(fd, body);
        return .{ .opcode = opcode, .body = body };
    }
};

fn writeAll(fd: linux.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = linux.write(fd, buf[off..].ptr, buf.len - off);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        off += n;
    }
}

fn readExact(fd: linux.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = linux.read(fd, buf[off..].ptr, buf.len - off);
        if (n == 0) return error.ConnectionClosed;
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        off += n;
    }
}

fn writeInt16(list: *std.array_list.AlignedManaged(u8, null), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try list.appendSlice(&buf);
}

fn writeInt32(list: *std.array_list.AlignedManaged(u8, null), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(&buf);
}

fn writeString(list: *std.array_list.AlignedManaged(u8, null), s: []const u8) !void {
    try writeInt16(list, @intCast(s.len));
    try list.appendSlice(s);
}

fn writeLongString(list: *std.array_list.AlignedManaged(u8, null), s: []const u8) !void {
    try writeInt32(list, @intCast(s.len));
    try list.appendSlice(s);
}

fn writeBytes(list: *std.array_list.AlignedManaged(u8, null), b: []const u8) !void {
    try writeInt32(list, @intCast(b.len));
    try list.appendSlice(b);
}

fn writeStringMap(list: *std.array_list.AlignedManaged(u8, null), entries: anytype) !void {
    try writeInt16(list, @intCast(entries.len));
    for (entries) |e| {
        try writeString(list, e.k);
        try writeString(list, e.v);
    }
}

const Cursor = struct {
    buf: []const u8,
    pos: usize,

    fn rdI32(self: *Cursor) !i32 {
        const v = std.mem.readInt(i32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn rdI16(self: *Cursor) !i16 {
        const v = std.mem.readInt(i16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn string(self: *Cursor) ![]const u8 {
        const n = try self.rdI16();
        const s = self.buf[self.pos..][0..@intCast(n)];
        self.pos += @intCast(n);
        return s;
    }

    fn bytes(self: *Cursor) !?[]const u8 {
        const n = try self.rdI32();
        if (n < 0) return null;
        const s = self.buf[self.pos..][0..@intCast(n)];
        self.pos += @intCast(n);
        return s;
    }
};

fn parseTypeOption(cur: *Cursor, alloc: std.mem.Allocator) !i32 {
    const id = try cur.rdI16();
    switch (id) {
        0 => _ = try cur.string(), // custom class name
        32, 33 => _ = try parseTypeOption(cur, alloc), // list / set element
        34 => { // map key/value
            _ = try parseTypeOption(cur, alloc);
            _ = try parseTypeOption(cur, alloc);
        },
        24 => { // UDT
            _ = try cur.string();
            _ = try cur.string();
            const n = try cur.rdI16();
            var i: i16 = 0;
            while (i < n) : (i += 1) {
                _ = try cur.string();
                _ = try parseTypeOption(cur, alloc);
            }
        },
        25 => { // tuple
            const n = try cur.rdI16();
            var i: i16 = 0;
            while (i < n) : (i += 1) {
                _ = try parseTypeOption(cur, alloc);
            }
        },
        else => {},
    }
    return id;
}

fn parseResult(alloc: std.mem.Allocator, body: []const u8) !QueryResult {
    var cur = Cursor{ .buf = body, .pos = 0 };
    const kind = try cur.rdI32();
    if (kind != 2) {
        return QueryResult{ .allocator = alloc, .columns = &.{}, .rows = &.{} };
    }

    const flags = try cur.rdI32();
    const colcount = try cur.rdI32();
    const global_spec = (flags & 0x0001) != 0;

    if (global_spec) {
        _ = try cur.string(); // keyspace
        _ = try cur.string(); // table
    }

    const columns = try alloc.alloc(Column, @intCast(colcount));
    var i: usize = 0;
    while (i < columns.len) : (i += 1) {
        if (!global_spec) {
            _ = try cur.string(); // keyspace
            _ = try cur.string(); // table
        }
        const name = try alloc.dupe(u8, try cur.string());
        const tid = try parseTypeOption(&cur, alloc);
        columns[i] = .{ .name = name, .type_id = tid };
    }

    const rowcount = try cur.rdI32();
    const rows = try alloc.alloc(Row, @intCast(rowcount));
    var r: usize = 0;
    while (r < rows.len) : (r += 1) {
        const cells = try alloc.alloc(Cell, columns.len);
        var c: usize = 0;
        while (c < cells.len) : (c += 1) {
            const val = try cur.bytes();
            cells[c] = .{
                .type_id = columns[c].type_id,
                .data = if (val) |v| try alloc.dupe(u8, v) else null,
            };
        }
        rows[r] = .{ .cells = cells };
    }

    return QueryResult{ .allocator = alloc, .columns = columns, .rows = rows };
}

fn writeJsonString(list: *List, s: []const u8) !void {
    try list.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice("\\\""),
            '\\' => try list.appendSlice("\\\\"),
            '\n' => try list.appendSlice("\\n"),
            '\r' => try list.appendSlice("\\r"),
            '\t' => try list.appendSlice("\\t"),
            else => try list.append(c),
        }
    }
    try list.append('"');
}

fn uuidHex(alloc: std.mem.Allocator, b: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    var h: [32]u8 = undefined;
    for (b, 0..) |byte, idx| {
        h[2 * idx] = hex[(byte >> 4) & 0xf];
        h[2 * idx + 1] = hex[byte & 0xf];
    }
    const out = try alloc.alloc(u8, 36);
    @memcpy(out[0..8], h[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], h[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], h[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], h[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], h[20..32]);
    return out;
}

fn writeValue(list: *List, alloc: std.mem.Allocator, cell: Cell) !void {
    if (cell.data == null) {
        try list.appendSlice("null");
        return;
    }
    const b = cell.data.?;
    switch (cell.type_id) {
        1, 12 => try writeJsonString(list, b), // ascii / varchar
        9 => {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{std.mem.readInt(i32, b[0..4], .big)});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        2, 5 => {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{std.mem.readInt(i64, b[0..8], .big)});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        18 => {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{std.mem.readInt(i16, b[0..2], .big)});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        19 => {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{b[0]});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        4 => try list.appendSlice(if (b[0] == 0) "false" else "true"),
        7 => {
            const v = std.mem.readInt(u64, b[0..8], .big);
            const s = try std.fmt.allocPrint(alloc, "{d}", .{@as(f64, @bitCast(v))});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        8 => {
            const v = std.mem.readInt(u32, b[0..4], .big);
            const s = try std.fmt.allocPrint(alloc, "{d}", .{@as(f32, @bitCast(v))});
            defer alloc.free(s);
            try list.appendSlice(s);
        },
        11, 14 => {
            const hex = try uuidHex(alloc, b);
            defer alloc.free(hex);
            try writeJsonString(list, hex);
        },
        else => try writeJsonString(list, b),
    }
}

// ===================== Tests =====================

test "cassandra live round-trip (set CASSANDRA_TEST=1 to run)" {
    if (std.testing.environ.getPosix("CASSANDRA_TEST")) |_| {} else return;
    const host = std.testing.environ.getPosix("CASSANDRA_HOST") orelse "127.0.0.1";
    const port = std.fmt.parseInt(u16, std.testing.environ.getPosix("CASSANDRA_PORT") orelse "9042", 10) catch 9042;
    const hostport = try std.fmt.allocPrint(std.testing.allocator, "{s}:{d}", .{ host, port });
    defer std.testing.allocator.free(hostport);

    // Connect without a keyspace: a fresh container has none, so the client must
    // not issue `USE` until this test creates it. Statements qualify the
    // keyspace explicitly instead.
    var conn = Connection.init(std.testing.allocator, hostport, "cassandra", "cassandra", null);
    defer conn.deinit();

    var rv = try conn.query("SELECT release_version FROM system.local");
    defer rv.deinit();
    try std.testing.expect(rv.rows.len >= 1);

    _ = try conn.query("CREATE KEYSPACE IF NOT EXISTS zero_test WITH replication = {'class':'SimpleStrategy','replication_factor':1}");
    _ = try conn.query("CREATE TABLE IF NOT EXISTS zero_test.users (id text primary key, data text)");
    _ = try conn.query("INSERT INTO zero_test.users (id, data) VALUES ('alice', '{\"age\":30}')");

    var got = try conn.query("SELECT data FROM zero_test.users WHERE id = 'alice'");
    defer got.deinit();
    try std.testing.expect(got.rows.len == 1);
    const cell = got.rows[0].cells[0];
    try std.testing.expect(cell.data != null);
    try std.testing.expectEqualStrings("{\"age\":30}", cell.data.?);
}
