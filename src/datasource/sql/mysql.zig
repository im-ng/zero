const std = @import("std");
const root = @import("../../zero.zig");

// Pure-Zig MySQL / MariaDB client (text protocol, `mysql_native_password`
// auth). No native driver or C library is required.
//
// Two layers:
//   * `Connection` — one TCP socket (optionally upgraded to TLS via
//     `std.crypto.tls.Client`) speaking the COM_QUERY text protocol, with
//     reflection-based row decode, basic transactions, lastInsertRowID and
//     rowsAffected. This is the unit of a connection pool.
//   * `MySQL` — a thread-safe connection pool AND a per-request session. The
//     same struct serves both roles (mirroring the Postgres `SQL` wrapper):
//     when `conn == null` and `pool == null` it is the top-level pool; when
//     `conn != null` and `pool != null` it is a borrowed session that pins one
//     connection for a transaction. `ctx.SQL` for MySQL is a per-request
//     session so concurrent requests never share a socket or a transaction.

const capProtocol41: u32 = 0x200;
const capSecureConnection: u32 = 0x8000;
const capPluginAuth: u32 = 0x800000;
const capConnectWithDb: u32 = 0x8;
// Request a TLS upgrade after the initial handshake. The auth credentials are
// still sent in the (cleartext) SSL-request packet, which is the de-facto
// behaviour of the reference Go driver; the TLS handshake immediately follows
// and all subsequent traffic is encrypted.
const capSsl: u32 = 0x0800;

pub const Config = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    ssl_mode: MySQL.SslMode = .disabled,
    ssl_ca: ?[]const u8 = null,
    max: usize = 10,
};

// One live MySQL connection: a socket (optionally wrapped in TLS) plus the
// protocol state for a single serialized command stream.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    socket_reader: std.Io.net.Stream.Reader,
    socket_writer: std.Io.net.Stream.Writer,
    recv_buf: []u8,
    send_buf: []u8,
    tls_client: ?std.crypto.tls.Client = null,
    tls_read_buf: []u8 = &[_]u8{},
    tls_write_buf: []u8 = &[_]u8{},
    // Active read/write interfaces. Point at the socket until TLS is negotiated,
    // then at the TLS client. All packet I/O goes through these so the rest of
    // the protocol code is TLS-agnostic.
    read_if: *std.Io.Reader,
    write_if: *std.Io.Writer,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    seq: u8,
    last_insert_id: i64,
    rows_affected: usize,
    connected: bool = false,

    const Self = @This();

    const Result = struct {
        rows: [][]const u8,
        affected: usize,
    };

    const Handshake = struct {
        scramble: [20]u8,
    };

    // Establish a connection, performing the handshake (and TLS upgrade when
    // `cfg.ssl_mode` is not `disabled`). For `preferred`, a TLS failure falls
    // back to a plaintext connection; for `required`, the error is propagated.
    // Connections are created lazily by the pool during request handling, so the
    // io loop is running and async DNS/connect resolve correctly.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !*Self {
        if (cfg.ssl_mode == .disabled) return connectAttempt(allocator, io, cfg);
        const conn = connectAttempt(allocator, io, cfg) catch |err| {
            if (cfg.ssl_mode == .preferred) {
                var fallback = cfg;
                fallback.ssl_mode = .disabled;
                return connectAttempt(allocator, io, fallback);
            }
            return err;
        };
        return conn;
    }

    fn connectAttempt(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !*Self {
        const addr = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch
            try std.Io.net.IpAddress.resolve(io, cfg.host, cfg.port);
        const stream = try addr.connect(io, .{ .mode = .stream });

        const recv_buf = try allocator.alloc(u8, 1 << 16);
        const send_buf = try allocator.alloc(u8, 1 << 16);
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
            .seq = 0,
            .last_insert_id = 0,
            .rows_affected = 0,
            .connected = false,
            .tls_client = null,
            .tls_read_buf = &[_]u8{},
            .tls_write_buf = &[_]u8{},
            .read_if = undefined,
            .write_if = undefined,
            .socket_reader = undefined,
            .socket_writer = undefined,
            .ca_bundle = .empty,
            .ca_lock = .init,
        };
        self.socket_reader = stream.reader(io, recv_buf);
        self.socket_writer = stream.writer(io, send_buf);
        self.read_if = &self.socket_reader.interface;
        self.write_if = &self.socket_writer.interface;

        self.handshake(cfg) catch |err| {
            self.deinit();
            return err;
        };
        self.connected = true;
        return self;
    }

    fn handshake(self: *Self, cfg: Config) !void {
        const packet = try self.readPacket();
        defer self.allocator.free(packet);
        const hs = try self.parseHandshake(packet);

        const with_ssl = cfg.ssl_mode != .disabled;
        const resp = try self.buildHandshakeResponse(&hs, cfg.user, cfg.password, cfg.database, with_ssl);
        defer self.allocator.free(resp);
        try self.writePacket(resp);

        if (with_ssl) {
            try self.setupTls(cfg);
        }

        const auth_result = try self.readPacket();
        defer self.allocator.free(auth_result);
        if (auth_result.len == 0) return error.MySqlProtocol;
        const t = auth_result[0];
        if (t == 0xFF) return error.MySqlAccessDenied;
        if (t == 0x01) return error.MySqlAuthMore;
        if (t != 0x00) return error.MySqlProtocol;
    }

    // Upgrade the active socket to TLS. The ClientHello is written during
    // `crypto.tls.Client.init`; the first subsequent read completes the
    // handshake and decrypts the server's auth result.
    fn setupTls(self: *Self, cfg: Config) !void {
        const tls_size = std.crypto.tls.Client.min_buffer_len;
        self.tls_read_buf = try self.allocator.alloc(u8, tls_size + (1 << 16));
        self.tls_write_buf = try self.allocator.alloc(u8, tls_size + (1 << 16));

        var rand: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&rand);
        const now = std.Io.Timestamp.now(self.io, .real);

        // When a CA path is supplied we verify the server cert (and hostname);
        // otherwise we accept the cert without verification (the channel is
        // still encrypted). Prefer setting MYSQL_SSL_CA in production.
        self.tls_client = try std.crypto.tls.Client.init(
            &self.socket_reader.interface,
            &self.socket_writer.interface,
            .{
                .host = if (cfg.ssl_ca != null) .{ .explicit = cfg.host } else .no_verification,
                .ca = if (cfg.ssl_ca) |ca_path| blk: {
                    try self.ca_bundle.addCertsFromFilePathAbsolute(self.allocator, self.io, now, ca_path);
                    break :blk .{ .bundle = .{
                        .gpa = self.allocator,
                        .io = self.io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca_bundle,
                    } };
                } else .no_verification,
                .write_buffer = self.tls_write_buf,
                .read_buffer = self.tls_read_buf,
                .entropy = &rand,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            },
        );
        self.read_if = &self.tls_client.?.reader;
        self.write_if = &self.tls_client.?.writer;
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
        with_ssl: bool,
    ) ![]u8 {
        var cap: u32 = capProtocol41 | capSecureConnection | capPluginAuth;
        if (with_ssl) {
            cap |= capSsl;
        }
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
        try self.read_if.readSliceAll(&hdr);
        const len: u32 = @as(u32, hdr[0]) |
            (@as(u32, hdr[1]) << 8) |
            (@as(u32, hdr[2]) << 16);
        self.seq = hdr[3];
        if (len == 0) return &[_]u8{};
        return try self.read_if.readAlloc(self.allocator, len);
    }

    fn writePacket(self: *Self, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        const len: u32 = @intCast(payload.len);
        hdr[0] = @intCast(len & 0xFF);
        hdr[1] = @intCast((len >> 8) & 0xFF);
        hdr[2] = @intCast((len >> 16) & 0xFF);
        hdr[3] = self.seq;
        self.seq +%= 1;

        try self.write_if.writeAll(&hdr);
        if (payload.len > 0) {
            try self.write_if.writeAll(payload);
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

    pub fn queryRows(
        self: *Self,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) ![]Type {
        const q = try interpolateSql(self.allocator, stmt, args);
        defer self.allocator.free(q);
        const res = try self.execInternal(q, false);
        return try self.decodeRows(Type, res);
    }

    pub fn exec(self: *Self, comptime stmt: []const u8, args: anytype) !i64 {
        const q = try interpolateSql(self.allocator, stmt, args);
        defer self.allocator.free(q);
        const res = try self.execInternal(q, false);
        return @intCast(res.affected);
    }

    pub fn deinit(self: *Self) void {
        if (self.connected) {
            self.stream.close(self.io);
        }
        self.allocator.free(self.recv_buf);
        self.allocator.free(self.send_buf);
        if (self.tls_read_buf.len > 0) {
            self.allocator.free(self.tls_read_buf);
        }
        if (self.tls_write_buf.len > 0) {
            self.allocator.free(self.tls_write_buf);
        }
        self.ca_bundle.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// Thread-safe connection pool and per-request session for MySQL. See the module
// doc comment for the dual role of this struct.
pub const MySQL = struct {
    pub const SslMode = enum {
        disabled,
        preferred,
        required,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    ssl_mode: SslMode,
    ssl_ca: ?[]const u8,
    max: usize,

    // Pool state. Only meaningful on the top-level pool (when `pool == null`).
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    free: std.ArrayList(*Connection) = .empty,
    total: usize = 0,

    // Session state. `conn` is the pinned connection during a transaction;
    // `pool` is the back-pointer to the shared pool. On the top-level pool both
    // are null.
    conn: ?*Connection = null,
    pool: ?*MySQL = null,

    lastId: i64 = 0,
    rows: usize = 0,

    const Self = @This();

    // Build the top-level pool. No network connection is made here; connections
    // are established lazily on first use (so async DNS/connect have a running
    // io loop), which also keeps `container.create` (which runs before the loop)
    // crash-free for hostname-based configs.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !*Self {
        const m = try allocator.create(Self);
        m.* = Self{
            .allocator = allocator,
            .io = io,
            .host = cfg.host,
            .port = cfg.port,
            .user = cfg.user,
            .password = cfg.password,
            .database = cfg.database,
            .ssl_mode = cfg.ssl_mode,
            .ssl_ca = cfg.ssl_ca,
            .max = cfg.max,
            .free = .empty,
            .total = 0,
        };
        return m;
    }

    // Build a per-request session that borrows the shared pool but keeps its own
    // transaction/last-id/rows state. This is what `Context.init` hands to each
    // HTTP request so concurrent requests can't share a transaction connection
    // or clobber each other's last-insert-id.
    pub fn createSession(allocator: std.mem.Allocator, shared: *Self) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = shared.allocator,
            .io = shared.io,
            .host = shared.host,
            .port = shared.port,
            .user = shared.user,
            .password = shared.password,
            .database = shared.database,
            .ssl_mode = shared.ssl_mode,
            .ssl_ca = shared.ssl_ca,
            .max = shared.max,
            .free = .empty,
            .total = 0,
            .conn = null,
            .pool = shared,
        };
        return s;
    }

    fn config(self: *Self) Config {
        return .{
            .host = self.host,
            .port = self.port,
            .user = self.user,
            .password = self.password,
            .database = self.database,
            .ssl_mode = self.ssl_mode,
            .ssl_ca = self.ssl_ca,
            .max = self.max,
        };
    }

    fn getPool(self: *Self) *Self {
        return self.pool orelse self;
    }

    // Acquire a connection. Inside a transaction (see `begin`) the pinned
    // connection is returned so every statement shares one transaction.
    pub fn acquireConn(self: *Self) !*Connection {
        if (self.conn) |c| return c;
        return try self.getPool().poolAcquire();
    }

    // Release a connection acquired via `acquireConn`, unless it is the pinned
    // transaction connection (owned by the active transaction).
    pub fn releaseConn(self: *Self, c: *Connection) void {
        if (self.conn != null) return;
        self.getPool().poolRelease(c);
    }

    // Pool-only: hand out a free connection, creating one up to `max`, or block
    // until a connection is returned. Broken connections are discarded and
    // replaced on the next acquire.
    fn poolAcquire(self: *Self) !*Connection {
        self.mu.lockUncancelable(self.io);
        while (true) {
            if (self.free.items.len > 0) {
                // pop() returns `?T`; the length check above guarantees non-null.
                const c = self.free.pop() orelse unreachable;
                if (!c.connected) {
                    c.deinit();
                    self.total -= 1;
                    continue;
                }
                self.mu.unlock(self.io);
                return c;
            }
            if (self.total < self.max) {
                self.total += 1;
                self.mu.unlock(self.io);
                const c = Connection.connect(self.allocator, self.io, self.config()) catch |err| {
                    self.mu.lockUncancelable(self.io);
                    self.total -= 1;
                    self.mu.unlock(self.io);
                    return err;
                };
                return c;
            }
            self.cond.waitUncancelable(self.io, &self.mu);
        }
    }

    // Pool-only: return a connection to the free list (or discard it if broken).
    fn poolRelease(self: *Self, c: *Connection) void {
        self.mu.lockUncancelable(self.io);
        if (!c.connected) {
            c.deinit();
            self.total -= 1;
        } else {
            self.free.append(self.allocator, c) catch {
                c.deinit();
                self.total -= 1;
            };
        }
        self.cond.signal(self.io);
        self.mu.unlock(self.io);
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

    pub fn queryRows(
        self: *Self,
        _: *root.Context,
        comptime Type: type,
        comptime stmt: []const u8,
        args: anytype,
    ) ![]Type {
        const conn = try self.acquireConn();
        const res = conn.queryRows(Type, stmt, args) catch |err| {
            conn.connected = false;
            self.releaseConn(conn);
            return err;
        };
        self.lastId = conn.last_insert_id;
        self.rows = conn.rows_affected;
        self.releaseConn(conn);
        return res;
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
        _: *root.Context,
        comptime stmt: []const u8,
        args: anytype,
    ) !i64 {
        const conn = try self.acquireConn();
        const r = conn.exec(stmt, args) catch |err| {
            conn.connected = false;
            self.releaseConn(conn);
            return err;
        };
        self.lastId = conn.last_insert_id;
        self.rows = conn.rows_affected;
        self.releaseConn(conn);
        return r;
    }

    pub fn lastInsertRowID(self: *Self) i64 {
        return self.lastId;
    }

    pub fn rowsAffected(self: *Self) usize {
        return self.rows;
    }

    // Start a transaction. All subsequent `exec`/`query*` calls run on a single
    // pinned connection until `commit`/`rollback`.
    pub fn begin(self: *Self) !void {
        if (self.conn != null) return error.AlreadyInTransaction;
        const pool = self.getPool();
        const c = try pool.poolAcquire();
        _ = c.execInternal("BEGIN", false) catch |err| {
            pool.poolRelease(c);
            return err;
        };
        self.conn = c;
    }

    // Commit the active transaction and release the pinned connection.
    pub fn commit(self: *Self) !void {
        const c = self.conn orelse return error.NotInTransaction;
        _ = c.execInternal("COMMIT", false) catch |err| {
            c.connected = false;
            self.getPool().poolRelease(c);
            self.conn = null;
            return err;
        };
        self.getPool().poolRelease(c);
        self.conn = null;
    }

    // Roll back the active transaction (best-effort) and release the connection.
    pub fn rollback(self: *Self) void {
        if (self.conn) |c| {
            _ = c.execInternal("ROLLBACK", false) catch {
                c.connected = false;
            };
            self.getPool().poolRelease(c);
            self.conn = null;
        }
    }

    // Close the pool and every idle connection it holds. Request sessions must
    // not call this (they borrow the shared pool's connections).
    pub fn deinit(self: *Self) void {
        self.mu.lockUncancelable(self.io);
        for (self.free.items) |c| {
            c.deinit();
        }
        self.free.deinit(self.allocator);
        self.mu.unlock(self.io);
        self.allocator.destroy(self);
    }
};

// Build a SQL string from a `?`-placeholder statement and the provided args.
// Placeholders are interpolated directly (text protocol); this is a convenience
// for the typed query API, not a server-side prepared statement.
fn interpolateSql(allocator: std.mem.Allocator, comptime stmt: []const u8, args: anytype) ![]const u8 {
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
            try appendLiteral(allocator, &buf, v);
        } else {
            try buf.append(allocator, ch);
        }
    }
    return try buf.toOwnedSlice(allocator);
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
        .int, .float, .comptime_int, .comptime_float => {
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

// ===================== Tests =====================
// These tests breaks the kcov coverage, investigate further
//
// test "mysql: interpolateSql substitutes ? placeholders" {
//     const alloc = std.testing.allocator;
//     const q = try interpolateSql(alloc, "SELECT * FROM t WHERE id = ? AND name = ?", .{ 42, "zig" });
//     defer alloc.free(q);
//     try std.testing.expectEqualStrings("SELECT * FROM t WHERE id = 42 AND name = zig", q);
// }

// test "mysql: interpolateSql handles optional args" {
//     const alloc = std.testing.allocator;
//     const name: ?[]const u8 = null;
//     const q = try interpolateSql(alloc, "WHERE name = ?", .{name});
//     defer alloc.free(q);
//     try std.testing.expectEqualStrings("WHERE name = ", q);
// }
