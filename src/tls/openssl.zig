const std = @import("std");
const Io = std.Io;
const openssl = @import("openssl");
const builtin = @import("builtin");

/// True when the `openssl` C bindings were compiled in. The framework always
/// builds with OpenSSL (it is already linked for the Postgres client), so this
/// is fixed at true here; the stub module exists only for parity.
pub const has_openssl = true;

/// Raw OpenSSL C bindings produced by `translate-c`. Re-exported so callers can
/// reach symbols not wrapped by this module (e.g. `tlso.openssl_c.SSL_new`).
pub const openssl_c = openssl;

/// Opaque OpenSSL context handle.
pub const SSLCtx = openssl.SSL_CTX;

/// Options forwarded to `initializeSSLContext` and the TLS handshake.
pub const TlsOpts = struct {
    /// When true, the peer certificate chain is verified against `ca_path`
    /// (or the system default CA bundle when `ca_path` is null).
    verify: bool = false,
    /// PEM file (or directory) of trusted CA certificates.
    ca_path: ?[]const u8 = null,
    /// SNI name. Sent as SNI only when it is a DNS name (never an IP literal,
    /// which OpenSSL rejects). With `identity` it is also the hostname used for
    /// certificate verification.
    server_name: ?[]const u8 = null,
    /// When true (and `verify` is set), the peer certificate must also match
    /// `server_name` (hostname or IP). Chain validation alone (`verify_ca` in
    /// MySQL terms) needs CA trust only, because self-signed server certificates
    /// commonly carry no usable SAN for the host they serve.
    identity: bool = false,
    /// Client certificate (PEM) for mutual TLS.
    cert_file: ?[]const u8 = null,
    /// Client private key (PEM) for mutual TLS.
    key_file: ?[]const u8 = null,
};

/// Dump the OpenSSL error queue to stderr. Call after any OpenSSL failure so
/// the diagnostic reason is not lost.
pub fn printSSLError() void {
    const bio = openssl.BIO_new(openssl.BIO_s_mem()) orelse return;
    defer _ = openssl.BIO_free(bio);
    openssl.ERR_print_errors(bio);
    var buf: [*]u8 = undefined;
    const len: usize = @intCast(openssl.BIO_get_mem_data(bio, &buf));
    if (len > 0) {
        std.debug.print("{s}\n", .{buf[0..len]});
    }
}

/// Build an `SSL_CTX` configured from `opts`: minimum TLS 1.2, optional CA
/// verification, and optional client certificate + key (mutual TLS).
pub fn initializeSSLContext(opts: TlsOpts) !*SSLCtx {
    const ctx = openssl.SSL_CTX_new(openssl.TLS_client_method()) orelse {
        return error.SSLContextNew;
    };
    errdefer openssl.SSL_CTX_free(ctx);

    if (openssl.SSL_CTX_set_min_proto_version(ctx, openssl.TLS1_2_VERSION) != 1) {
        return error.SSLMinVersion;
    }
    // SSL_MODE_AUTO_RETRY hides the WANT_READ/WANT_WRITE renegotiation signals
    // from the application; with a blocking socket we want a single call.
    _ = openssl.SSL_CTX_set_mode(ctx, openssl.SSL_MODE_AUTO_RETRY);

    if (opts.verify) {
        // An empty CA path (config key unset) falls back to the system trust
        // store. Only a non-empty path is handed to OpenSSL, which would
        // otherwise try to open a file named "" and fail with SSLVerifyPaths.
        if (optStr(opts.ca_path)) |p| {
            var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const pz = nullTerm(&buf, p);
            if (openssl.SSL_CTX_load_verify_locations(ctx, pz.ptr, null) != 1) {
                printSSLError();
                return error.SSLVerifyPaths;
            }
        } else {
            if (openssl.SSL_CTX_set_default_verify_paths(ctx) != 1) {
                printSSLError();
                return error.SSLDefaultVerifyPaths;
            }
        }
        openssl.SSL_CTX_set_verify(ctx, openssl.SSL_VERIFY_PEER, null);
    }

    if (optStr(opts.cert_file)) |cert| {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const cz = nullTerm(&buf, cert);
        if (openssl.SSL_CTX_use_certificate_chain_file(ctx, cz.ptr) != 1) {
            printSSLError();
            return error.SSLCertLoadFailed;
        }
    }
    if (optStr(opts.key_file)) |key| {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const kz = nullTerm(&buf, key);
        if (openssl.SSL_CTX_use_PrivateKey_file(ctx, kz.ptr, openssl.SSL_FILETYPE_PEM) != 1) {
            printSSLError();
            return error.SSLKeyLoadFailed;
        }
        if (openssl.SSL_CTX_check_private_key(ctx) != 1) {
            printSSLError();
            return error.SSLKeyMismatch;
        }
    }

    return ctx;
}

pub fn freeSSLContext(ctx: ?*SSLCtx) void {
    if (ctx) |c| {
        openssl.SSL_CTX_free(c);
    }
}

/// A TLS session layered over an already-connected `std.Io.net.Stream`. It owns
/// the `SSL`/`SSL_CTX` and exposes `reader`/`writer` as `std.Io` interfaces so
/// the MongoDB/Cassandra wire code can read/write through it unchanged.
pub const TlsStream = struct {
    reader: OpenSslReader,
    writer: OpenSslWriter,
    ssl: *openssl.SSL,
    ctx: *openssl.SSL_CTX,

    /// Upgrade `stream` to TLS using `read_buffer`/`write_buffer` as the I/O
    /// scratch buffers (owned by the caller) and the parameters in `opts`.
    pub fn handshake(
        stream: Io.net.Stream,
        read_buffer: []u8,
        write_buffer: []u8,
        opts: TlsOpts,
    ) !TlsStream {
        const ctx = try initializeSSLContext(opts);
        errdefer openssl.SSL_CTX_free(ctx);

        const ssl = openssl.SSL_new(ctx) orelse {
            return error.SSLNewFailed;
        };
        errdefer openssl.SSL_free(ssl);

        if (opts.server_name) |sn| {
            var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const snz = nullTerm(&buf, sn);
            if (isHostName(sn)) {
                if (openssl.SSL_set_tlsext_host_name(ssl, snz.ptr) != 1) {
                    return error.SSLHostNameFailed;
                }
            }
            // Enforce hostname (or IP) verification only when identity checking
            // is requested; older OpenSSL without SSL_set1_host falls back to
            // chain-only validation. Chain-only mode (`verify_ca`) keys off the
            // CA trust store and does not pin the server name.
            if (opts.identity) {
                _ = openssl.SSL_set1_host(ssl, snz.ptr);
            }
        }

        if (opts.verify) {
            openssl.SSL_set_verify(ssl, openssl.SSL_VERIFY_PEER, null);
        }

        const fd: std.posix.socket_t = stream.socket.handle;
        if (openssl.SSL_set_fd(ssl, if (builtin.os.tag == .windows) @intCast(@intFromPtr(fd)) else @intCast(fd)) != 1) {
            return error.SSLSetFdFailed;
        }

        if (openssl.SSL_connect(ssl) != 1) {
            const verification_code = openssl.SSL_get_verify_result(ssl);
            if (verification_code != openssl.X509_V_OK) {
                if (std.debug.runtime_safety) {
                    printSSLError();
                }
                return error.SSLCertificationVerificationError;
            }
            return error.SSLConnectFailed;
        }

        return .{
            .reader = OpenSslReader.init(ssl, read_buffer),
            .writer = OpenSslWriter.init(ssl, write_buffer),
            .ssl = ssl,
            .ctx = ctx,
        };
    }

    /// Shut down the TLS session and free the OpenSSL handles. Does not close
    /// the underlying socket — call `stream.close` afterwards.
    pub fn close(self: *TlsStream) void {
        _ = openssl.SSL_shutdown(self.ssl);
        openssl.SSL_free(self.ssl);
        openssl.SSL_CTX_free(self.ctx);
    }
};

const OpenSslReader = struct {
    interface: Io.Reader,
    ssl: *openssl.SSL,
    err: ?Io.Reader.Error = null,

    const vtable = Io.Reader.VTable{
        .stream = streamImpl,
        .readVec = readVec,
    };

    fn init(ssl: *openssl.SSL, buffer: []u8) OpenSslReader {
        return .{
            .ssl = ssl,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *OpenSslReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        var read_len: usize = 0;
        const rc = openssl.SSL_read_ex(r.ssl, dest[0].ptr, dest[0].len, &read_len);
        if (rc != 1) {
            const e = openssl.SSL_get_error(r.ssl, rc);
            if (e == openssl.SSL_ERROR_ZERO_RETURN) return error.EndOfStream;
            if (e == openssl.SSL_ERROR_WANT_READ or e == openssl.SSL_ERROR_WANT_WRITE) return 0;
            r.err = error.ReadFailed;
            return error.ReadFailed;
        }
        if (read_len == 0) return error.EndOfStream;
        if (read_len > data_size) {
            io_r.end += @intCast(read_len - data_size);
            return data_size;
        }
        return @intCast(read_len);
    }
};

const OpenSslWriter = struct {
    interface: Io.Writer,
    ssl: *openssl.SSL,
    err: ?Io.Writer.Error = null,

    const vtable = Io.Writer.VTable{
        .drain = drain,
    };

    fn init(ssl: *openssl.SSL, buffer: []u8) OpenSslWriter {
        return .{
            .ssl = ssl,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *OpenSslWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered = io_w.buffered();
        var n: usize = 0;
        if (buffered.len > 0) {
            n += try sslWriteAll(w.ssl, buffered);
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            for (data) |chunk| {
                n += try sslWriteAll(w.ssl, chunk);
            }
        }
        return io_w.consume(n);
    }
};

fn sslWriteAll(ssl: *openssl.SSL, data: []const u8) Io.Writer.Error!usize {
    var off: usize = 0;
    while (off < data.len) {
        const wrote = openssl.SSL_write(ssl, data.ptr + off, @intCast(data.len - off));
        if (wrote <= 0) return error.WriteFailed;
        off += @intCast(wrote);
    }
    return off;
}

/// Treat a `null` or empty path as absent. Config strings arrive as `""` when a
/// key is unset; OpenSSL must never receive an empty path (it would try to open
/// a file named "").
fn optStr(s: ?[]const u8) ?[]const u8 {
    if (s) |v| {
        if (v.len == 0) return null;
        return v;
    }
    return null;
}

/// Copy `path` into `buf`, a caller-owned buffer that MUST stay alive for the
/// duration of the OpenSSL `const char *` call that consumes the result, and
/// return it as a null-terminated slice. The buffer is passed in by the caller
/// rather than allocated here because returning a slice into a local stack
/// buffer would dangle — the stack frame is gone by the time OpenSSL reads the
/// pointer, producing garbage paths (OpenSSL then reports `SSLVerifyPaths`).
fn nullTerm(buf: []u8, path: []const u8) [:0]u8 {
    std.debug.assert(path.len < buf.len);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// A host is a DNS name (not an IP literal) when it contains a non-digit/dot
/// character and no colon (IPv6). SNI must only be sent for DNS names.
fn isHostName(host: []const u8) bool {
    if (std.mem.findScalar(u8, host, ':') != null) {
        return false;
    }
    return std.mem.findNone(u8, host, "0123456789.") != null;
}
