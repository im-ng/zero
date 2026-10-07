const std = @import("std");
const root = @import("../../zero.zig");

// Pure-Zig MySQL / MariaDB client (text protocol, `mysql_native_password`
// auth). No native driver or C library is required, mirroring the framework's
// other vendored backends (ClickHouse/DuckGres over pure-Zig clients).
//
// Scope for the stable gate: a single shared connection (one command at a
// time), COM_QUERY text protocol, reflection-based row decode, basic
// transactions (BEGIN/COMMIT/ROLLBACK), lastInsertRowID and rowsAffected.
// Prepared statements, SSL, and connection pooling are deliberately out of
// scope for now (documented limitation, see parity report Phase 1).

pub const MySQL = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    recv_buf: []u8,
    send_buf: []u8,
    seq: u8,
    last_insert_id: i64,
    rows_affected: usize,

    const Self = @This();

    const capProtocol41: u32 = 0x200;
    const capSecureConnection: u32 = 0x8000;
    const capPluginAuth: u32 = 0x800000;
    const capConnectWithDb: u32 = 0x8;

    const Result = struct {
        rows: [][]const u8,
        affected: usize,
    };

    const Handshake = struct {
        scramble: [20]u8,
    };

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8,
        database: []const u8,
    ) !*Self {
        const addr = try std.Io.net.IpAddress.parse(host, port);
        const conn = try addr.connect(io, .{ .mode = .stream });

        const recv_buf = try allocator.alloc(u8, 1 << 16);
        const send_buf = try allocator.alloc(u8, 1 << 16);
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .conn = conn,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
            .seq = 0,
            .last_insert_id = 0,
            .rows_affected = 0,
            .reader = conn.reader(io, recv_buf),
        };
        try self.handshake(user, password, database);
        return self;
    }

    fn handshake(self: *Self, user: []const u8, password: []const u8, database: []const u8) !void {
        const packet = try self.readPacket();
        defer self.allocator.free(packet);
        const hs = try self.parseHandshake(packet);

        self.seq = 1;
        const resp = try self.buildHandshakeResponse(&hs, user, password, database);
        defer self.allocator.free(resp);
        try self.writePacket(resp);

        const auth_result = try self.readPacket();
        defer self.allocator.free(auth_result);
        if (auth_result.len == 0) return error.MySqlProtocol;
        const t = auth_result[0];
        if (t == 0xFF) return error.MySqlAccessDenied;
        if (t == 0x01) return error.MySqlAuthMore;
        if (t != 0x00) return error.MySqlProtocol;
    }

    fn parseHandshake(self: *Self, packet: []const u8) !Handshake {
        _ = self;
        var off: usize = 0;
        // protocol version (1) + server version (null-terminated) + thread id (4)
        off += 1;
        while (off < packet.len and packet[off] != 0) off += 1;
        off += 1;
        off += 4;
        const part1 = packet[off .. off + 8];
        off += 8;
        off += 1; // filler
        off += 2; // capability flags (lower 2 bytes)
        const part2 = packet[off .. off + 12];

        var scramble: [20]u8 = undefined;
        @memcpy(scramble[0..8], part1);
        @memcpy(scramble[8..20], part2);
        return Handshake{ .scramble = scramble };
    }

    fn buildHandshakeResponse(
        self: *Self,
        hs: *const Handshake,
        user: []const u8,
        password: []const u8,
        database: []const u8,
    ) ![]u8 {
        var cap: u32 = capProtocol41 | capSecureConnection | capPluginAuth;
        if (database.len > 0) {
            cap |= capConnectWithDb;
        }

        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.allocator, std.mem.toBytes(cap)[0..4]);
        // max packet size (4 bytes): 1 << 16
        try buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 1, 0 });
        // charset (utf8mb4 = 0x21)
        try buf.append(self.allocator, 0x21);
        // reserved (23 bytes)
        var filler: [23]u8 = undefined;
        @memset(&filler, 0);
        try buf.appendSlice(self.allocator, &filler);
        // username (null-terminated)
        try buf.appendSlice(self.allocator, user);
        try buf.append(self.allocator, 0);
        // auth response (length-encoded)
        if (password.len == 0) {
            try buf.append(self.allocator, 0);
        } else {
            const token = try self.scrambleFromHandshake(&hs.scramble, password);
            defer self.allocator.free(token);
            try buf.append(self.allocator, @intCast(token.len));
            try buf.appendSlice(self.allocator, token);
        }
        // database (length-encoded, only when CONNECT_WITH_DB)
        if (database.len > 0) {
            try buf.append(self.allocator, @intCast(database.len));
            try buf.appendSlice(self.allocator, database);
        }
        // auth plugin name (null-terminated)
        try buf.appendSlice(self.allocator, "mysql_native_password");
        try buf.append(self.allocator, 0);

        return try buf.toOwnedSlice(self.allocator);
    }

    fn scrambleFromHandshake(self: *Self, hand: []const u8, password: []const u8) ![]u8 {
        var hash1 = std.crypto.hash.Sha1.init(.{});
        hash1.update(password);
        var h1: [20]u8 = undefined;
        hash1.final(&h1);

        var hash2 = std.crypto.hash.Sha1.init(.{});
        hash2.update(&h1);
        var h2: [20]u8 = undefined;
        hash2.final(&h2);

        var hash3 = std.crypto.hash.Sha1.init(.{});
        hash3.update(hand);
        hash3.update(&h2);
        var h3: [20]u8 = undefined;
        hash3.final(&h3);

        var token: [20]u8 = undefined;
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            token[i] = h1[i] ^ h3[i];
        }
        return try self.allocator.dupe(u8, &token);
    }

    fn readPacket(self: *Self) ![]u8 {
        var hdr: [4]u8 = undefined;
        const rdr = &self.reader.interface;
        try rdr.readSliceAll(&hdr);
        const len: u32 = @as(u32, hdr[0]) |
            (@as(u32, hdr[1]) << 8) |
            (@as(u32, hdr[2]) << 16);
        self.seq = hdr[3];
        if (len == 0) return &[_]u8{};
        return try rdr.readAlloc(self.allocator, len);
    }

    fn writePacket(self: *Self, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        const len: u32 = @intCast(payload.len);
        hdr[0] = @intCast(len & 0xFF);
        hdr[1] = @intCast((len >> 8) & 0xFF);
        hdr[2] = @intCast((len >> 16) & 0xFF);
        hdr[3] = self.seq;
        self.seq +%= 1;

        var w = self.conn.writer(self.io, self.send_buf);
        try w.interface.writeAll(&hdr);
        if (payload.len > 0) {
            try w.interface.writeAll(payload);
        }
    }

    fn sendComQuery(self: *Self, query: []const u8) !void {
        self.seq = 0;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const len: u32 = @intCast(query.len + 1);
        try buf.append(self.allocator, @intCast(len & 0xFF));
        try buf.append(self.allocator, @intCast((len >> 8) & 0xFF));
        try buf.append(self.allocator, @intCast((len >> 16) & 0xFF));
        try buf.append(self.allocator, 0); // sequence
        try buf.append(self.allocator, 0x03); // COM_QUERY
        try buf.appendSlice(self.allocator, query);
        try self.writePacket(buf.items);
    }

    fn readLenEncInt(self: *Self, buf: []const u8, off: *usize) !u64 {
        _ = self;
        const first = buf[off.*];
        if (first < 0xFB) {
            off.* += 1;
            return first;
        }
        if (first == 0xFB) {
            off.* += 1;
            return 0;
        }
        if (first == 0xFC) {
            const v = std.mem.readInt(u16, buf[off.* + 1 ..][0..2], .little);
            off.* += 3;
            return v;
        }
        if (first == 0xFD) {
            const v = std.mem.readInt(u24, buf[off.* + 1 ..][0..3], .little);
            off.* += 4;
            return v;
        }
        const v = std.mem.readInt(u64, buf[off.* + 1 ..][0..8], .little);
        off.* += 9;
        return v;
    }

    fn handleOk(self: *Self, packet: []const u8, drain: bool) !Result {
        var off: usize = 1;
        const affected = try self.readLenEncInt(packet, &off);
        const last_insert = try self.readLenEncInt(packet, &off);
        self.last_insert_id = @intCast(last_insert);
        self.rows_affected = @intCast(affected);
        if (drain) {
            const p = try self.readPacket();
            self.allocator.free(p);
        }
        return Result{ .rows = &[_][]const u8{}, .affected = @intCast(affected) };
    }

    fn handleResult(self: *Self, allocator: std.mem.Allocator, col_count: u64, drain: bool) !Result {
        _ = drain;
        var i: u64 = 0;
        while (i < col_count) : (i += 1) {
            const col = try self.readPacket();
            self.allocator.free(col);
        }
        var rows: std.ArrayList([]const u8) = .empty;
        while (true) {
            const packet = try self.readPacket();
            if (packet.len > 0 and packet[0] == 0xFE and packet.len < 9) {
                self.allocator.free(packet);
                break;
            }
            if (packet.len > 0 and packet[0] == 0xFF) {
                self.allocator.free(packet);
                return error.MySqlError;
            }
            try rows.append(allocator, try self.allocator.dupe(u8, packet));
            self.allocator.free(packet);
        }
        const count = rows.items.len;
        return Result{ .rows = try rows.toOwnedSlice(allocator), .affected = count };
    }

    fn execInternal(self: *Self, query: []const u8, drain: bool) !Result {
        try self.sendComQuery(query);
        const packet = try self.readPacket();
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.MySqlProtocol;
        const first = packet[0];
        if (first == 0xFF) return error.MySqlError;
        if (first == 0x00) return self.handleOk(packet, drain);
        if (first == 0xFE) return error.MySqlProtocol;
        var off: usize = 0;
        const col_count = try self.readLenEncInt(packet, &off);
        return try self.handleResult(self.allocator, col_count, drain);
    }

    fn collectFields(comptime Type: type) []const std.builtin.Type.StructField {
        comptime {
            const ti = @typeInfo(Type);
            if (ti != .@"struct") {
                @compileError("MySQL row type must be a struct");
            }
            return ti.@"struct".fields;
        }
    }

    fn decodeRow(
        self: *Self,
        comptime Type: type,
        packet: []const u8,
        comptime fields: []const std.builtin.Type.StructField,
    ) !Type {
        var row: Type = undefined;
        var off: usize = 0;
        inline for (fields) |field| {
            if (off < packet.len and packet[off] == 0xFB) {
                off += 1;
                if (@typeInfo(field.type) == .optional) {
                    @field(row, field.name) = null;
                }
            } else {
                const len = try self.readLenEncInt(packet, &off);
                const value = packet[off .. off + len];
                off += len;
                try self.parseField(&@field(row, field.name), value, field.type);
            }
        }
        return row;
    }

    fn parseField(self: *Self, dest: anytype, value: []const u8, comptime T: type) !void {
        const ti = @typeInfo(T);
        if (ti == .optional) {
            const Inner = ti.optional.child;
            var inner_val: Inner = undefined;
            try self.parseScalar(&inner_val, value, Inner);
            dest.* = inner_val;
            return;
        }
        try self.parseScalar(dest, value, T);
    }

    fn parseScalar(self: *Self, dest: anytype, value: []const u8, comptime T: type) !void {
        const ti = @typeInfo(T);
        switch (ti) {
            .int => {
                dest.* = try std.fmt.parseInt(T, value, 10);
            },
            .float => {
                dest.* = try std.fmt.parseFloat(T, value);
            },
            .bool => {
                dest.* = (std.mem.eql(u8, value, "1") or
                    std.mem.eql(u8, value, "true"));
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    dest.* = try self.allocator.dupe(u8, value);
                } else {
                    @compileError("unsupported mysql pointer field");
                }
            },
            else => @compileError("unsupported mysql field type: " ++ @typeName(T)),
        }
    }

    fn decodeRows(self: *Self, comptime Type: type, res: Result) ![]Type {
        const fields = comptime collectFields(Type);
        var list: std.ArrayList(Type) = .empty;
        for (res.rows) |packet| {
            try list.append(self.allocator, try self.decodeRow(Type, packet, fields));
        }
        for (res.rows) |r| {
            self.allocator.free(r);
        }
        self.allocator.free(res.rows);
        return try list.toOwnedSlice(self.allocator);
    }

    fn appendLiteral(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
        const T = @TypeOf(value);
        const ti = @typeInfo(T);
        if (ti == .optional) {
            if (value) |v| {
                try appendLiteral(allocator, buf, v);
            }
            return;
        }
        switch (ti) {
            .pointer => |p| {
                const is_u8_seq = if (p.child == u8) true else blk: {
                    const ci = @typeInfo(p.child);
                    break :blk switch (ci) {
                        .array => |a| a.child == u8,
                        else => false,
                    };
                };
                if (is_u8_seq) {
                    const s: []const u8 = if (p.size == .slice) value else value[0..];
                    try buf.appendSlice(allocator, s);
                } else {
                    @compileError("unsupported interpolation pointer: " ++ @typeName(@TypeOf(value)));
                }
            },
            .int, .float => {
                var tmp: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch "0";
                try buf.appendSlice(allocator, s);
            },
            .bool => {
                try buf.appendSlice(allocator, if (value) "1" else "0");
            },
            else => @compileError("unsupported interpolation type: " ++ @typeName(T)),
        }
    }

    fn interpolateSql(self: *Self, comptime stmt: []const u8, args: anytype) ![]const u8 {
        const ArgIndex = comptime blk: {
            var arr: [stmt.len]?usize = undefined;
            var counter: usize = 0;
            var k: usize = 0;
            while (k < stmt.len) : (k += 1) {
                if (stmt[k] == '?') {
                    arr[k] = counter;
                    counter += 1;
                } else {
                    arr[k] = null;
                }
            }
            break :blk arr;
        };
        var buf: std.ArrayList(u8) = .empty;
        inline for (stmt, ArgIndex) |ch, maybe_ai| {
            if (ch == '?') {
                const v = args[maybe_ai.?];
                try appendLiteral(self.allocator, &buf, v);
            } else {
                try buf.append(self.allocator, ch);
            }
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn queryRows(
        self: *Self,
        ctx: *root.Context,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) ![]Type {
        _ = ctx;
        const q = try self.interpolateSql(stmt, args);
        defer self.allocator.free(q);
        const res = try self.execInternal(q, false);
        return try self.decodeRows(Type, res);
    }

    pub fn queryRow(
        self: *Self,
        ctx: *root.Context,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) !?Type {
        const rows = try self.queryRows(ctx, Type, stmt, args);
        if (rows.len == 0) return null;
        const row = rows[0];
        self.allocator.free(rows);
        return row;
    }

    pub fn queryRowContext(
        self: *Self,
        ctx: *root.Context,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) !?Type {
        return try self.queryRow(ctx, Type, stmt, args);
    }

    pub fn queryRowsContext(
        self: *Self,
        ctx: *root.Context,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) ![]Type {
        return try self.queryRows(ctx, Type, stmt, args);
    }

    pub fn selectSlice(
        self: *Self,
        ctx: *root.Context,
        comptime Type: type,
        list: *std.array_list.Managed(Type),
        comptime stmt: []const u8,
        args: anytype,
    ) !i64 {
        const rows = try self.queryRows(ctx, Type, stmt, args);
        for (rows) |r| {
            try list.append(r);
        }
        self.allocator.free(rows);
        return @intCast(list.items.len);
    }

    pub fn execWithContext(
        self: *Self,
        ctx: *root.Context,
        comptime stmt: []const u8,
        args: anytype,
    ) !i64 {
        _ = ctx;
        const q = try self.interpolateSql(stmt, args);
        defer self.allocator.free(q);
        const res = try self.execInternal(q, false);
        return @intCast(res.affected);
    }

    pub fn lastInsertRowID(self: *Self) i64 {
        return self.last_insert_id;
    }

    pub fn rowsAffected(self: *Self) usize {
        return self.rows_affected;
    }

    pub fn begin(self: *Self) !void {
        _ = try self.execInternal("BEGIN", false);
    }

    pub fn commit(self: *Self) !void {
        _ = try self.execInternal("COMMIT", false);
    }

    pub fn rollback(self: *Self) !void {
        _ = try self.execInternal("ROLLBACK", false);
    }
};
