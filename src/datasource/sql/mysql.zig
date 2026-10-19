const std = @import("std");
const root = @import("../../zero.zig");
const tlso = root.tlso;

// Pure-Zig MySQL / MariaDB client (text protocol). Supports both
// `mysql_native_password` (SHA1) and `caching_sha2_password` (SHA256 fast-auth;
// full-auth as cleartext over TLS, or RSA-OAEP over a plain socket via the
// server's public key) so it works against MySQL 8.0+ defaults with and
// without TLS. No native driver or C library is required.
//
// Two layers:
//   * `Connection` — one TCP socket (optionally upgraded to TLS via the
//     framework's OpenSSL layer `tlso`) speaking the COM_QUERY text protocol, with
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
// Cap on how long `poolAcquire` blocks waiting for a free connection before
// failing fast (audit #16). A saturated pool should not hang a request forever.
const pool_acquire_timeout_ms: u64 = 30_000;
// Bounded reconnect loop for a fresh connection (the Postgres backend already
// retries; MySQL had none — a transient blip failed the request instantly,
// audit #30). Short backoff between attempts; the per-attempt connect timeout
// (10s) still bounds each try.
const mysql_connect_retries: usize = 3;
const mysql_connect_backoff_ms: u64 = 50;

// Build an `Io.Timeout` from a millisecond budget. `Clock.Duration` carries a
// clock tag, but for a relative timeout only the raw nanoseconds matter, so any
// clock is valid (audit #16).
fn timeoutFromMs(ms: u64) std.Io.Timeout {
    return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real } };
}
const capPluginAuth: u32 = 0x80000;
const capConnectWithDb: u32 = 0x8;
// Request a TLS upgrade after the initial handshake. The upgrade is
// protocol-correct: first a bare SSL-request packet (no credentials on the
// wire), then the TLS handshake, then the full handshake response through the
// encrypted channel.
const capSsl: u32 = 0x0800;

const rsa = @import("rsa.zig");

pub const Config = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    ssl_mode: MySQL.SslMode = .disabled,
    ssl_ca: ?[]const u8 = null,
    max: usize = 10,
    // Cap on the TCP connect + handshake; a dead/unreachable host must not hang a
    // request thread or pin a pool slot forever (audit #16).
    connect_timeout_ms: u64 = 10_000,
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
    tls_stream: ?tlso.TlsStream = null,
    tls_read_buf: []u8 = &[_]u8{},
    tls_write_buf: []u8 = &[_]u8{},
    // Active read/write interfaces. Point at the socket until TLS is negotiated,
    // then at the TLS client. All packet I/O goes through these so the rest of
    // the protocol code is TLS-agnostic.
    read_if: *std.Io.Reader,
    write_if: *std.Io.Writer,
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
        auth_plugin: []const u8,
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
        const stream = try addr.connect(io, .{
            .mode = .stream,
            .timeout = timeoutFromMs(cfg.connect_timeout_ms),
        });

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
            .tls_stream = null,
            .tls_read_buf = &[_]u8{},
            .tls_write_buf = &[_]u8{},
            .read_if = undefined,
            .write_if = undefined,
            .socket_reader = undefined,
            .socket_writer = undefined,
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
        if (cfg.password.len > 255) {
            // The auth-response length encodes into one length-encoded byte
            // in every plugin this client speaks, so absurdly long passwords
            // would overflow the wire format; reject them up-front.
            return error.MySqlPasswordTooLong;
        }
        const packet = try self.readPacket();
        defer self.allocator.free(packet);
        const hs = try self.parseHandshake(packet);
        defer self.allocator.free(hs.auth_plugin);

        // The server advertises its auth plugin in the handshake. MySQL 8.0+
        // defaults to caching_sha2_password, which needs a separate (SHA256)
        // flow from the legacy mysql_native_password (SHA1) one.
        const use_caching = std.mem.eql(u8, hs.auth_plugin, "caching_sha2_password");
        const plugin = if (use_caching) "caching_sha2_password" else "mysql_native_password";
        const token = if (cfg.password.len == 0)
            try self.allocator.dupe(u8, "")
        else if (use_caching)
            try self.scrambleSha256(&hs.scramble, cfg.password)
        else
            try self.scrambleFromHandshake(&hs.scramble, cfg.password);
        defer self.allocator.free(token);

        const with_ssl = cfg.ssl_mode != .disabled;
        if (with_ssl) {
            // Protocol-correct TLS upgrade: a bare SSL-request packet (no
            // credentials) first, then the TLS handshake, then the full
            // handshake response re-sent through the encrypted channel.
            // Sending credentials before the upgrade (as some drivers
            // historically did) leaks the password scramble in cleartext,
            // and the server never consumes auth data that early anyway.
            const sreq = try self.buildSslRequest();
            defer self.allocator.free(sreq);
            try self.writePacket(sreq);
            try self.setupTls(cfg);
        }

        const resp = try self.buildHandshakeResponse(cfg.user, cfg.database, with_ssl, plugin, token);
        defer self.allocator.free(resp);
        try self.writePacket(resp);

        // Auth-result loop: after the handshake response the server walks us
        // through a small state machine — an OK packet (fast path), an ERR
        // packet, an AuthSwitchRequest (0xFE — cold-cache servers ask the
        // client to re-derive its token against a fresh scramble before any
        // 0x01 traffic flows), or AuthMoreData (caching_sha2 fast-auth /
        // full-auth subcodes). Every non-terminal reply is followed by
        // another packet, so respond and loop until OK or ERR arrives.
        //
        // `scramble_current` tracks which scramble the server considered when
        // evaluating every subsequent token: the greeting's until a switch
        // request replaces it, and the one a full-auth encrypt must XOR
        // against.
        var scramble_current = hs.scramble;
        var rounds: usize = 0;

        while (rounds < 8) : (rounds += 1) {
            const auth_result = try self.readPacket();
            defer self.allocator.free(auth_result);
            if (auth_result.len == 0) return error.MySqlProtocol;
            const t = auth_result[0];
            if (t == 0x00) {
                return; // terminal OK — authentication succeeded
            }
            if (t == 0xFF) {
                // Surface the server's own text (errno + message) so a
                // mis-numbered protocol step is not indistinguishable from
                // a wrong password.
                self.logServerErr(auth_result, "handshake auth rejected");
                return error.MySqlAccessDenied;
            }
            if (t == 0xFE) {
                // AuthSwitchRequest: plugin name (NUL-terminated) then the
                // server's scramble (NUL-terminated). Re-derive the token
                // with the plugin's hashing scheme and resend it as a bare
                // AuthSwitchResponse (no status-prefixed payload).
                scramble_current = try self.authSwitchResponse(cfg, auth_result[1..]);
                continue;
            }
            if (t == 0x01) {
                // AuthMoreData: only expected during caching_sha2 negotiation.
                if (!use_caching or auth_result.len < 2) return error.MySqlAuthMore;
                switch (auth_result[1]) {
                    // 0x03 = fast auth succeeded (server had the cached hash;
                    // confirmed against libmysqlclient wire captures). The
                    // trailing OK packet is the loop's next read.
                    0x03 => {},
                    // 0x04 = full auth required (cold cache): over TLS the
                    // password travels as cleartext inside the encrypted
                    // channel; without TLS it is RSA-OAEP-encrypted with the
                    // server's public key. The next reply (consumed by the
                    // loop) is the terminal OK.
                    0x04 => {
                        try self.cachingSha2FullAuth(cfg, with_ssl, scramble_current);
                    },
                    0x01 => {
                        // Fast auth succeeded; the server still sends a
                        // trailing OK packet, which the loop reads next.
                    },
                    else => return error.MySqlProtocol,
                }
                continue;
            }
            return error.MySqlProtocol;
        }
        return error.MySqlProtocol; // auth loop exceeded its step budget
    }

    // Answer an AuthSwitchRequest (0xFE packet body). Parses the plugin name
    // and scramble, rebuilds the per-plugin token, and sends it. Returns the
    // scramble the caller should use for any later full-auth exchange.
    fn authSwitchResponse(self: *Self, cfg: Config, body: []const u8) ![20]u8 {
        var off: usize = 0;
        const nul_plugin = std.mem.indexOfScalar(u8, body, 0) orelse return error.MySqlProtocol;
        const switch_plugin = body[0..nul_plugin];
        off = nul_plugin + 1;
        if (off >= body.len) return error.MySqlProtocol;
        const nul_scramble_end = std.mem.indexOfScalarPos(u8, body, off, 0) orelse body.len;
        if (nul_scramble_end - off != 20) return error.MySqlProtocol;
        var scramble: [20]u8 = undefined;
        @memcpy(scramble[0..20], body[off..nul_scramble_end]);

        const token = if (std.mem.eql(u8, switch_plugin, "caching_sha2_password"))
            try self.scrambleSha256(&scramble, cfg.password)
        else if (std.mem.eql(u8, switch_plugin, "mysql_native_password"))
            try self.scrambleFromHandshake(&scramble, cfg.password)
        else
            return error.MySqlAuthMore;
        defer self.allocator.free(token);
        try self.writePacket(token);
        return scramble;
    }

    // Complete a caching_sha2_password full-auth exchange. The server sends
    // AuthMoreData (0x01 0x03) when the password hash isn't cached. The
    // exchange matches go-sql-driver/mysql `encryptPassword`: over TLS the
    // NUL-terminated password is sent in cleartext into the encrypted channel;
    // without TLS the client requests the server's RSA public key and sends
    // the NUL-terminated password (XORed with the cycled handshake scramble)
    // RSA-OAEP-SHA1-encrypted with it.
    fn cachingSha2FullAuth(self: *Self, cfg: Config, with_ssl: bool, scramble: [20]u8) !void {
        if (with_ssl) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, cfg.password);
            try buf.append(self.allocator, 0); // the protocol includes a NUL terminator
            try self.writePacket(buf.items);
        } else {
            // Ask the server for its RSA public key: payload is a single 0x02
            // byte, and the answer is an AuthMoreData packet carrying the key.
            try self.writePacket(&[_]u8{0x02});
            const key_pkt = try self.readPacket();
            defer self.allocator.free(key_pkt);
            if (key_pkt.len < 2 or key_pkt[0] != 0x01) return error.MySqlProtocol;

            // The server wraps the key in PEM; tolerate a bare DER body too.
            const pem_or_der = try rsa.pemDecode(self.allocator, key_pkt[1..]);
            defer if (pem_or_der) |der| self.allocator.free(der);
            const der = pem_or_der orelse key_pkt[1..];
            const key = try rsa.parseSpki(der);

            // plain = NUL-terminated password XOR the 20-byte handshake
            // scramble cycled to the password length.
            const plain = try self.allocator.alloc(u8, cfg.password.len + 1);
            defer self.allocator.free(plain);
            @memcpy(plain[0..cfg.password.len], cfg.password);
            plain[cfg.password.len] = 0;
            for (plain, 0..) |b, i| {
                plain[i] = b ^ scramble[i % scramble.len];
            }

            var seed: [rsa.oaepSeedLen]u8 = undefined;
            self.io.random(&seed);
            const enc = try rsa.encryptOaep(self.allocator, key, plain, seed);
            defer self.allocator.free(enc);
            try self.writePacket(enc);
        }
        const r = try self.readPacket();
        defer self.allocator.free(r);
        if (r.len == 0) return error.MySqlProtocol;
        if (r[0] == 0xFF) {
            self.logServerErr(r, "full-auth rejected");
            return error.MySqlAccessDenied;
        }
        if (r[0] != 0x00) return error.MySqlProtocol;
    }

    // Decode a MySQL ERR packet (0xFF || errno LE u16 || optional '#'+5-byte
    // sqlstate || message) and print it with the phase that failed. This
    // writes to stderr because the Connection layer has no logger handle —
    // the app logger is threaded only from App down through SQL/container, and
    // adding one here would pull in modules outside this file.
    fn logServerErr(self: *Self, packet: []const u8, phase: []const u8) void {
        _ = self;
        if (packet.len < 3) return;
        const errno = std.mem.readInt(u16, packet[1..3], .little);
        var msg_start: usize = 3;
        if (packet.len > 9 and packet[3] == '#') {
            msg_start = 9;
        }
        const msg = packet[msg_start..];
        std.debug.print("[mysql] {s}: server error {d}: {s}\n", .{ phase, errno, msg });
    }

    // Upgrade the active socket to TLS via the framework's OpenSSL layer
    // (`tlso.TlsStream`). std.crypto.tls.Client cannot speak to this server:
    // MySQL's TLS 1.3 flow carries a CertificateRequest handshake message
    // (peer captures confirm it for both libmysqlclient and Go clients),
    // which std's client has no case for and fails with TlsUnexpectedMessage.
    // OpenSSL answers it with an empty client certificate, so the upgrade
    // completes normally. The ClientHello is written during `handshake`; the
    // first subsequent read completes it and decrypts the server's auth
    // result.
    fn setupTls(self: *Self, cfg: Config) !void {
        self.tls_read_buf = try self.allocator.alloc(u8, 1 << 16);
        self.tls_write_buf = try self.allocator.alloc(u8, 1 << 16);

        // When a CA path is supplied we verify the server cert (and hostname);
        // otherwise we accept the cert without verification (the channel is
        // still encrypted). Prefer setting MYSQL_SSL_CA in production.
        // `verify_ca` validates the certificate chain against `ssl_ca` (or the
        // system default bundle when null) without pinning the server host —
        // MySQL's self-signed certificates carry no SAN for the serving host.
        // `verify_identity` additionally enforces hostname/IP match.
        const verify_only = cfg.ssl_mode == .verify_ca;
        const verify_identity = cfg.ssl_mode == .verify_identity;
        self.tls_stream = try tlso.TlsStream.handshake(self.stream, self.tls_read_buf, self.tls_write_buf, .{
            .verify = verify_only or verify_identity,
            .identity = verify_identity,
            .ca_path = cfg.ssl_ca,
            .server_name = cfg.host,
        });
        self.read_if = &self.tls_stream.?.reader.interface;
        self.write_if = &self.tls_stream.?.writer.interface;
    }

    fn parseHandshake(self: *Self, packet: []const u8) !Handshake {
        var off: usize = 0;
        if (packet.len < 1) return error.MySqlProtocol;
        // protocol version (1) + server version (null-terminated) + thread id (4)
        off += 1;
        while (off < packet.len and packet[off] != 0) off += 1;
        if (off == packet.len) return error.MySqlProtocol; // no NUL terminator
        off += 1;
        off += 4;
        // From here on everything up to part2's end is fixed-size: the greeting
        // must carry 8 scramble bytes + 1 filler + 2 low caps + 1 charset +
        // 2 status + 2 high caps + 1 plugin-data length + 10 reserved + 12
        // part2 bytes. A shorter packet (garbled server/proxy) is rejected
        // instead of read out of bounds.
        if (packet.len < off + 8 + 1 + 2 + 1 + 2 + 2 + 1 + 10 + 12) return error.MySqlProtocol;
        const part1 = packet[off .. off + 8];
        off += 8;
        off += 1; // filler
        off += 2; // capability flags (lower 2 bytes)
        off += 1; // character set
        off += 2; // status flags
        off += 2; // capability flags (upper 2 bytes)
        off += 1; // length of auth-plugin-data
        off += 10; // reserved
        const part2 = packet[off .. off + 12];
        // auth-plugin-name: null-terminated string immediately after part2
        // (part2 is 12 data bytes + 1 null terminator in the wire format).
        var plugin_off = off + 13;
        if (plugin_off > packet.len) {
            plugin_off = packet.len;
        }
        var pend = plugin_off;
        while (pend < packet.len and packet[pend] != 0) pend += 1;
        const plugin = if (pend > plugin_off)
            try self.allocator.dupe(u8, packet[plugin_off..pend])
        else
            try self.allocator.dupe(u8, "mysql_native_password");

        var scramble: [20]u8 = undefined;
        @memcpy(scramble[0..8], part1);
        @memcpy(scramble[8..20], part2);
        return Handshake{ .scramble = scramble, .auth_plugin = plugin };
    }

    // Bare SSL-request packet (32 bytes): capability flags with CLIENT_SSL,
    // max packet size, charset, 23 reserved zero bytes — never credentials.
    // The full handshake response travels through TLS after the upgrade.
    fn buildSslRequest(self: *Self) ![]u8 {
        var cap: u32 = capProtocol41 | capSecureConnection | capPluginAuth;
        cap |= capSsl;

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
        return try buf.toOwnedSlice(self.allocator);
    }

    fn buildHandshakeResponse(
        self: *Self,
        user: []const u8,
        database: []const u8,
        with_ssl: bool,
        plugin: []const u8,
        token: []const u8,
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
        // auth response (length-encoded). An empty token (no password) is a single
        // 0x00 length byte.
        if (token.len == 0) {
            try buf.append(self.allocator, 0);
        } else {
            try buf.append(self.allocator, @intCast(token.len));
            try buf.appendSlice(self.allocator, token);
        }
        // database (NUL-terminated string, only when CONNECT_WITH_DB). The
        // 4.1 handshake response declares the default schema as string[NUL] —
        // not length-encoded — verified byte-for-byte against libmysqlclient:
        // a length byte here makes the server fold our plugin name and any
        // trailing bytes into a garbled unknown-database name.
        if (database.len > 0) {
            try buf.appendSlice(self.allocator, database);
            try buf.append(self.allocator, 0);
        }
        // auth plugin name (null-terminated)
        try buf.appendSlice(self.allocator, plugin);
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

    // caching_sha2_password fast-auth token:
    //   SHA256(password) XOR SHA256(SHA256(SHA256(password)) ++ scramble)
    // Note the nesting order differs from mysql_native_password: here the
    // double-hashed password is prepended to the scramble (PyMySQL, the Go
    // driver and the C client all do it in this order). Building it as
    // SHA256(scramble ++ double_hash) — the native convention — makes the
    // server treat the token as a wrong password and return AccessDenied.
    fn scrambleSha256(self: *Self, hand: []const u8, password: []const u8) ![]u8 {
        var hash1 = std.crypto.hash.sha2.Sha256.init(.{});
        hash1.update(password);
        var h1: [32]u8 = undefined;
        hash1.final(&h1);

        var hash2 = std.crypto.hash.sha2.Sha256.init(.{});
        hash2.update(&h1);
        var h2: [32]u8 = undefined;
        hash2.final(&h2);

        var hash3 = std.crypto.hash.sha2.Sha256.init(.{});
        hash3.update(&h2);
        hash3.update(hand);
        var h3: [32]u8 = undefined;
        hash3.final(&h3);

        var token: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
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
        // Track the *client's* next sequence: each side's packet must be one
        // past the peer's last packet, so ingesting the server's seq + 1 makes
        // the next writePacket (and every full-auth/COM_QUERY exchange) land on
        // the number the server expects. Storing the server's raw seq instead
        // sent every client packet one short and MySQL mis-handshakes with
        // spurious ER_ACCESS_DENIED. `sendComQuery` resets to 0 to start the
        // command phase.
        self.seq = hdr[3] +% 1;
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
        // The 0.16 Writer interface is buffered (64 KB socket buffer here);
        // without an explicit drain the packet sits unsent and the server
        // times out with ER_NET_READ_TIMEOUT instead of replying.
        try self.write_if.flush();
    }

    fn sendComQuery(self: *Self, query: []const u8) !void {
        self.seq = 0;
        // Payload only: COM_QUERY + text. `writePacket` supplies the 4-byte
        // length/sequence header (building one here as well double-wrapped the
        // header on the wire, which the server saw as an unknown command).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.append(self.allocator, 0x03); // COM_QUERY
        try buf.appendSlice(self.allocator, query);
        try self.writePacket(buf.items);
    }

    fn readLenEncInt(self: *Self, buf: []const u8, off: *usize) !u64 {
        _ = self;
        if (off.* >= buf.len) return error.MySqlProtocol;
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
            if (off.* + 3 > buf.len) return error.MySqlProtocol;
            const v = std.mem.readInt(u16, buf[off.* + 1 ..][0..2], .little);
            off.* += 3;
            return v;
        }
        if (first == 0xFD) {
            if (off.* + 4 > buf.len) return error.MySqlProtocol;
            const v = std.mem.readInt(u24, buf[off.* + 1 ..][0..3], .little);
            off.* += 4;
            return v;
        }
        if (off.* + 9 > buf.len) return error.MySqlProtocol;
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
        // Without CLIENT_DEPRECATE_EOF the server sends an EOF after the column
        // definitions and a second one after the rows. Only the second one
        // terminates the row set; breaking at the first returned zero rows.
        var saw_column_eof = false;
        while (true) {
            const packet = try self.readPacket();
            if (packet.len > 0 and packet[0] == 0xFE and packet.len < 9) {
                if (saw_column_eof) {
                    self.allocator.free(packet);
                    break;
                }
                saw_column_eof = true;
                self.allocator.free(packet);
                continue;
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
        if (first == 0xFF) {
            // Surface the server's text (errno + message) so protocol-level
            // rejections during command phase are not indistinguishable from
            // application SQL errors.
            self.logServerErr(packet, "sql exec rejected");
            return error.MySqlError;
        }
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
                if (@typeInfo(field.type) != .optional) {
                    // A NULL column landing in a non-optional field would
                    // otherwise leave the field holding undefined memory;
                    // fail instead of returning poison (same rule duckdb.zig
                    // applies via NonNullColumnIsNull).
                    return error.NonNullColumnIsNull;
                }
                @field(row, field.name) = null;
            } else {
                if (off >= packet.len) return error.MySqlProtocol;
                const len = try self.readLenEncInt(packet, &off);
                if (off + len > packet.len) return error.MySqlProtocol;
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
        // `exec` only reports affected rows; the raw text rows (`res.rows`)
        // belong to the caller of `execInternal`, so release them here.
        for (res.rows) |r| {
            self.allocator.free(r);
        }
        self.allocator.free(res.rows);
        return @intCast(res.affected);
    }

    pub fn deinit(self: *Self) void {
        if (self.tls_stream) |*ts| {
            ts.close();
            self.tls_stream = null;
        }
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
        // TLS always, and the server certificate chain is verified against
        // `ssl_ca` (or the system default bundle when `ssl_ca` is null).
        verify_ca,
        // Like verify_ca, plus hostname/IP identity validation of the
        // certificate against the configured host.
        verify_identity,
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
    // Signalling primitive for connection availability. An `Event` (rather than a
    // `Condition`) lets `poolAcquire` bound the wait with a deadline so a fully
    // saturated pool fails fast instead of hanging a request forever (audit #16).
    event: std.Io.Event = .unset,
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

    // On a failed query, only a transport/protocol failure (not a SQL error from
    // an ERR packet) means the connection is broken. Poisoning on `MySqlError`
    // would discard a perfectly good connection and thrash the pool (audit #17).
    // Releases the connection and returns the error to the caller, which then
    // propagates it with its own return type.
    fn failConn(self: *Self, conn: *Connection, err: anyerror) void {
        if (err != error.MySqlError) {
            conn.connected = false;
        }
        self.releaseConn(conn);
    }

    // Pool-only: hand out a free connection, creating one up to `max`, or block
    // (bounded by `pool_acquire_timeout_ms`) until a connection is returned.
    // Broken connections are discarded and replaced on the next acquire.
    fn poolAcquire(self: *Self) !*Connection {
        self.mu.lockUncancelable(self.io);
        const deadline = if (pool_acquire_timeout_ms > 0)
            std.Io.Timeout.toTimestamp(timeoutFromMs(pool_acquire_timeout_ms), self.io)
        else
            null;
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
                // Retry transient connect failures a few times before giving up,
                // so a brief network blip doesn't fail the request (audit #30).
                var last_err: anyerror = error.MySqlConnectFailed;
                var attempt: usize = 0;
                while (attempt < mysql_connect_retries) : (attempt += 1) {
                    const c = Connection.connect(self.allocator, self.io, self.config()) catch |err| {
                        last_err = err;
                        if (attempt + 1 < mysql_connect_retries) {
                            std.Io.Timeout.sleep(timeoutFromMs(mysql_connect_backoff_ms), self.io) catch {};
                        }
                        continue;
                    };
                    return c;
                }
                self.mu.lockUncancelable(self.io);
                self.total -= 1;
                self.mu.unlock(self.io);
                return last_err;
            }
            // Pool is saturated: wait for a release, bounded by the deadline so a
            // permanently saturated pool fails fast instead of hanging the request.
            self.event.reset();
            // Re-check after the reset: a release may have set the event in the
            // window, in which case we must not block (lost-signal avoidance).
            if (self.free.items.len > 0 or self.total < self.max) continue;
            if (deadline) |dl| {
                self.mu.unlock(self.io);
                self.event.waitTimeout(self.io, .{ .deadline = dl }) catch |e| switch (e) {
                    error.Timeout => {
                        self.mu.lockUncancelable(self.io);
                        self.mu.unlock(self.io);
                        return error.MySqlPoolExhausted;
                    },
                    else => {},
                };
                self.mu.lockUncancelable(self.io);
            } else {
                self.mu.unlock(self.io);
                self.event.waitUncancelable(self.io);
                self.mu.lockUncancelable(self.io);
            }
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
        self.event.set(self.io);
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
            self.failConn(conn, err);
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
            self.failConn(conn, err);
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
            if (err != error.MySqlError) {
                c.connected = false;
            }
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
            _ = c.execInternal("ROLLBACK", false) catch |err| {
                if (err != error.MySqlError) {
                    c.connected = false;
                }
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
    @setEvalBranchQuota(2_000_000);
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
                // String values are interpolated as SQL string literals; wrap in
                // single quotes and double any embedded quote so values like
                // statuses/timestamps (and user input) are valid, not bare
                // identifiers that the server rejects as a syntax error.
                try buf.append(allocator, '\'');
                for (s) |ch| {
                    if (ch == '\'') {
                        try buf.appendSlice(allocator, "''");
                    } else {
                        try buf.append(allocator, ch);
                    }
                }
                try buf.append(allocator, '\'');
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
