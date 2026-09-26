const std = @import("std");
const utils = @import("../utils.zig");

const Io = std.Io;
const net = Io.net;
const crypto = std.crypto;

/// Pure-Zig MongoDB wire client (no C driver). Speaks the `OP_MSG` wire protocol
/// (opcode 2013) over `std.Io.net`, with optional TLS layered via
/// `std.crypto.tls.Client` — mirroring how `std.http.Client` wraps the same TLS
/// client over a preallocated, sliced buffer. Auth is `SCRAM-SHA-256`.
///
/// Targets MongoDB 5.0+ (OP_MSG only); no OP_QUERY handshake, no OP_COMPRESSED.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: ?crypto.tls.Client = null,
    ca_bundle: crypto.Certificate.Bundle,
    ca_lock: Io.RwLock = .init,
    reader: *Io.Reader,
    writer: *Io.Writer,
    buf: []u8,
    read_buf: []u8,
    write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    contact_points: []const u8,
    user: []const u8,
    pass: []const u8,
    auth_source: []const u8,
    db: []const u8,
    tls_enabled: bool,
    tls_verify: bool,
    tls_ca_path: ?[]const u8,
    connected: bool = false,
    request_id: u32 = 1,
    mutex: std.atomic.Mutex = .unlocked,

    const tls_buffer_size = crypto.tls.Client.min_buffer_len;
    const read_buffer_size = 1 << 16;
    const write_buffer_size = 1 << 16;

    fn lock(self: *Connection) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Connection) void {
        self.mutex.unlock();
    }

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        contact_points: []const u8,
        user: []const u8,
        pass: []const u8,
        auth_source: []const u8,
        db: []const u8,
        tls_enabled: bool = false,
        tls_verify: bool = false,
        tls_ca_path: ?[]const u8 = null,
    }) Connection {
        const alloc_len = (tls_buffer_size + read_buffer_size) + tls_buffer_size + write_buffer_size + tls_buffer_size;
        const buf = allocator.alloc(u8, alloc_len) catch @panic("oom");
        const tls_read_buf = buf[0 .. tls_buffer_size + read_buffer_size];
        const tls_write_buf = buf[tls_read_buf.len..][0..tls_buffer_size];
        const socket_write_buf = buf[tls_read_buf.len + tls_write_buf.len ..][0..write_buffer_size];
        const socket_read_buf = buf[tls_read_buf.len + tls_write_buf.len + socket_write_buf.len ..][0..tls_buffer_size];

        const self: Connection = .{
            .allocator = allocator,
            .stream = undefined,
            .stream_reader = undefined,
            .stream_writer = undefined,
            .tls_client = null,
            .ca_bundle = .empty,
            .reader = undefined,
            .writer = undefined,
            .buf = buf,
            .read_buf = socket_read_buf,
            .write_buf = socket_write_buf,
            .tls_read_buf = tls_read_buf,
            .tls_write_buf = tls_write_buf,
            .contact_points = opts.contact_points,
            .user = opts.user,
            .pass = opts.pass,
            .auth_source = opts.auth_source,
            .db = opts.db,
            .tls_enabled = opts.tls_enabled,
            .tls_verify = opts.tls_verify,
            .tls_ca_path = opts.tls_ca_path,
        };
        return self;
    }

    pub fn deinit(self: *Connection) void {
        if (self.connected) {
            self.stream.close(utils.io);
        }
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.buf);
        self.allocator.free(self.contact_points);
        self.allocator.free(self.user);
        self.allocator.free(self.pass);
        self.allocator.free(self.auth_source);
        self.allocator.free(self.db);
        if (self.tls_ca_path) |p| {
            self.allocator.free(p);
        }
    }

    fn ensureConnected(self: *Connection) !void {
        if (self.connected) return;
        var it = std.mem.tokenizeScalar(u8, self.contact_points, ',');
        while (it.next()) |cp| {
            const hostport = std.mem.trim(u8, cp, " ");
            const sep = std.mem.indexOfScalar(u8, hostport, ':') orelse continue;
            const host = hostport[0..sep];
            const port = std.fmt.parseInt(u16, std.mem.trim(u8, hostport[sep + 1 ..], " "), 10) catch continue;
            const stream = connectHost(host, port) catch continue;
            self.stream = stream;
            self.stream_reader = stream.reader(utils.io, self.read_buf);
            self.stream_writer = stream.writer(utils.io, self.write_buf);
            self.reader = &self.stream_reader.interface;
            self.writer = &self.stream_writer.interface;

            if (self.tls_enabled) {
                self.setupTls(host) catch {
                    stream.close(utils.io);
                    continue;
                };
            }

            self.handshake() catch {
                self.tls_client = null;
                stream.close(utils.io);
                continue;
            };

            if (self.user.len > 0) {
                self.authenticate() catch {
                    self.tls_client = null;
                    stream.close(utils.io);
                    continue;
                };
            }

            self.connected = true;
            return;
        }
        return error.MongoConnectionFailed;
    }

    fn setupTls(self: *Connection, host: []const u8) !void {
        var rand: [crypto.tls.Client.Options.entropy_len]u8 = undefined;
        utils.io.random(&rand);
        const now = Io.Timestamp.now(utils.io, .real);

        self.tls_client = try crypto.tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .host = if (self.tls_verify) .{ .explicit = host } else .no_verification,
                .ca = if (self.tls_verify and self.tls_ca_path != null) ca: {
                    self.ca_bundle.addCertsFromFilePathAbsolute(self.allocator, utils.io, now, self.tls_ca_path.?) catch return error.MongoTlsCaLoadFailed;
                    break :ca .{ .bundle = .{
                        .gpa = self.allocator,
                        .io = utils.io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca_bundle,
                    } };
                } else .no_verification,
                .write_buffer = self.write_buf,
                .read_buffer = self.tls_read_buf,
                .entropy = &rand,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            },
        );
        self.reader = &self.tls_client.?.reader;
        self.writer = &self.tls_client.?.writer;
    }

    fn handshake(self: *Connection) !void {
        const hello = try std.fmt.allocPrint(self.allocator, "{{\"hello\":1,\"helloOk\":true}}", .{});
        defer self.allocator.free(hello);
        const body = try jsonToBson(self.allocator, hello);
        defer self.allocator.free(body);
        const resp = try self.runOpMsg(body);
        defer self.allocator.free(resp);
        // A successful handshake replies with `ok: 1`.
        if (bsonFind(resp, "ok")) |ok| {
            if (ok != .double and ok != .int32 and ok != .int64) return error.MongoHandshakeFailed;
        } else return error.MongoHandshakeFailed;
    }

    fn authenticate(self: *Connection) !void {
        // client-first-message-bare = "n=<user>,r=<nonce>"
        var nonce: [24]u8 = undefined;
        utils.io.random(&nonce);
        const r = try b64Encode(self.allocator, &nonce);
        defer self.allocator.free(r);
        const client_first_bare = try std.fmt.allocPrint(self.allocator, "n={s},r={s}", .{ self.user, r });
        defer self.allocator.free(client_first_bare);
        const client_first = try std.fmt.allocPrint(self.allocator, "n,,{s}", .{client_first_bare});
        defer self.allocator.free(client_first);

        const sasl_start = try buildSaslStart(self.allocator, client_first, self.auth_source);
        defer self.allocator.free(sasl_start);
        const resp1 = try self.runOpMsg(sasl_start);
        defer self.allocator.free(resp1);

        const conv_id = if (bsonFind(resp1, "conversationId")) |v| switch (v) {
            .int32 => |x| x,
            .int64 => |x| @as(i32, @intCast(x)),
            else => return error.MongoAuthFailed,
        } else return error.MongoAuthFailed;

        const payload1 = if (bsonFind(resp1, "payload")) |v| switch (v) {
            .binary => |b| b,
            else => return error.MongoAuthFailed,
        } else return error.MongoAuthFailed;

        // server-first: r=<nonce>,s=<salt>,i=<iterations>
        const server_first = payload1;
        var it = std.mem.tokenizeScalar(u8, server_first, ',');
        var server_nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iterations: u32 = 0;
        while (it.next()) |part| {
            if (std.mem.startsWith(u8, part, "r=")) server_nonce = part[2..];
            if (std.mem.startsWith(u8, part, "s=")) salt_b64 = part[2..];
            if (std.mem.startsWith(u8, part, "i=")) iterations = std.fmt.parseInt(u32, part[2..], 10) catch 0;
        }
        if (iterations < 4096) return error.MongoAuthFailed;
        if (!std.mem.startsWith(u8, server_nonce, r)) return error.MongoAuthFailed;

        var pad: usize = 0;
        if (salt_b64.len > 0 and salt_b64[salt_b64.len - 1] == '=') {
            pad += 1;
        }
        if (salt_b64.len > 1 and salt_b64[salt_b64.len - 2] == '=') {
            pad += 1;
        }
        const salt = try self.allocator.alloc(u8, salt_b64.len / 4 * 3 - pad);
        std.base64.standard.Decoder.decode(salt, salt_b64) catch return error.MongoAuthFailed;
        defer self.allocator.free(salt);

        var salted: [32]u8 = undefined;
        try crypto.pwhash.pbkdf2(&salted, self.pass, salt, iterations, crypto.auth.hmac.sha2.HmacSha256);

        const client_final_bare = try std.fmt.allocPrint(self.allocator, "c=biws,r={s}", .{server_nonce});
        defer self.allocator.free(client_final_bare);

        const auth_message = try std.fmt.allocPrint(self.allocator, "{s},{s},{s}", .{ client_first_bare, server_first, client_final_bare });
        defer self.allocator.free(auth_message);

        const client_key = try hmacSha256(self.allocator, &salted, "Client Key");
        defer self.allocator.free(client_key);
        var stored_key: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(client_key, &stored_key, .{});
        const client_sig = try hmacSha256(self.allocator, &stored_key, auth_message);
        defer self.allocator.free(client_sig);
        const client_proof = try self.allocator.alloc(u8, client_key.len);
        defer self.allocator.free(client_proof);
        for (client_key, 0..) |b, i| {
            client_proof[i] = b ^ client_sig[i];
        }
        const proof_b64 = try b64Encode(self.allocator, client_proof);
        defer self.allocator.free(proof_b64);

        const client_final = try std.fmt.allocPrint(self.allocator, "{s},p={s}", .{ client_final_bare, proof_b64 });
        defer self.allocator.free(client_final);

        const sasl_continue = try buildSaslContinue(self.allocator, conv_id, client_final, self.auth_source);
        defer self.allocator.free(sasl_continue);
        const resp2 = try self.runOpMsg(sasl_continue);
        defer self.allocator.free(resp2);

        // A successful saslContinue replies with `ok: 1` and `done: true`.
        const resp2_ok = bsonFind(resp2, "ok") orelse return error.MongoAuthFailed;
        const ok_val: bool = switch (resp2_ok) {
            .double => |x| x == 1.0,
            .int32 => |x| x == 1,
            .int64 => |x| x == 1,
            else => false,
        };
        if (!ok_val) return error.MongoAuthFailed;
        if (bsonFind(resp2, "done")) |d| {
            const done = switch (d) {
                .boolean => |b| b,
                .int32 => |x| x != 0,
                .int64 => |x| x != 0,
                .double => |x| x != 0,
                else => true,
            };
            if (!done) return error.MongoAuthFailed;
        }
    }

    /// Run a MongoDB command `cmd_json` (a JSON document) against `db` and return
    /// the reply as a JSON string owned by `alloc`. Caller frees.
    pub fn runCommand(self: *Connection, alloc: std.mem.Allocator, db: []const u8, cmd_json: []const u8) ![]u8 {
        self.lock();
        defer self.unlock();
        try self.ensureConnected();

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, cmd_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.MongoCommandNotDocument;
        var list = std.array_list.Managed(u8).init(self.allocator);
        errdefer list.deinit();
        try bsonStart(&list);
        for (parsed.value.object.keys(), parsed.value.object.values()) |k, v| {
            try appendJsonField(&list, self.allocator, k, v);
        }
        // `$db` is a metadata field; MongoDB requires the command name to be
        // the document's first field, so append it after the command fields.
        try bsonAppendString(&list, "$db", db);
        try bsonFinish(&list);
        const body = try list.toOwnedSlice();
        defer self.allocator.free(body);

        const resp = try self.runOpMsg(body);
        defer self.allocator.free(resp);
        return try bsonToJson(alloc, resp);
    }

    fn runOpMsg(self: *Connection, body_bson: []const u8) ![]u8 {
        const writer = self.writer;
        const total: u32 = @intCast(16 + 4 + 1 + body_bson.len);
        var header: [16]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], total, .little);
        std.mem.writeInt(u32, header[4..8], self.request_id, .little);
        self.request_id +%= 1;
        std.mem.writeInt(u32, header[8..12], 0, .little); // responseTo
        std.mem.writeInt(u32, header[12..16], 2013, .little); // OP_MSG
        try writer.writeAll(&header);

        var flag_bits: [4]u8 = .{0} ** 4; // flagBits = 0, no checksum
        try writer.writeAll(&flag_bits);
        var kind: [1]u8 = .{0}; // section kind 0 (body)
        try writer.writeAll(&kind);
        try writer.writeAll(body_bson);
        try writer.flush();

        const reader = self.reader;
        var resp_header: [16]u8 = undefined;
        try reader.readSliceAll(&resp_header);
        const resp_total = std.mem.readInt(u32, resp_header[0..4], .little);
        const remaining = resp_total - 16;
        const raw = try self.allocator.alloc(u8, remaining);
        errdefer self.allocator.free(raw);
        try reader.readSliceAll(raw);
        // raw = flagBits(4) + section kind(1) + document (+ optional 4-byte
        // checksum when flagBits bit 0 is set). Strip the framing so callers
        // receive the bare BSON document.
        if (remaining < 5) return error.MongoProtocolError;
        const resp_flag_bits = std.mem.readInt(u32, raw[0..4], .little);
        const doc_start: usize = 5;
        const doc_end: usize = if ((resp_flag_bits & 1) != 0) remaining - 4 else remaining;
        const doc = raw[doc_start..doc_end];
        const owned = try self.allocator.dupe(u8, doc);
        self.allocator.free(raw);
        return owned;
    }
};

fn connectHost(host: []const u8, port: u16) !net.Stream {
    const addr = net.IpAddress.parse(host, port) catch try net.IpAddress.resolve(utils.io, host, port);
    return try addr.connect(utils.io, .{ .mode = .stream });
}

fn hmacSha256(alloc: std.mem.Allocator, key: []const u8, msg: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    const hmac = crypto.auth.hmac.sha2.HmacSha256.init(key);
    var ctx = hmac;
    ctx.update(msg);
    ctx.final(&out);
    return try alloc.dupe(u8, &out);
}

fn b64Encode(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(src.len);
    const buf = try alloc.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(buf, src);
    return buf;
}

// ===================== BSON =====================

fn bsonStart(list: *std.array_list.Managed(u8)) !void {
    // reserve 4-byte length prefix at the start of the buffer
    try list.appendNTimes(0, 4);
}

fn bsonFinish(list: *std.array_list.Managed(u8)) !void {
    // BSON length includes the 4-byte prefix and the trailing terminator.
    const len: u32 = @intCast(list.items.len + 1);
    std.mem.writeInt(u32, list.items[0..4], len, .little);
    try list.append(0x00); // terminator
}

fn bsonAppendInt32(list: *std.array_list.Managed(u8), name: []const u8, v: i32) !void {
    try list.append(0x10);
    try list.appendSlice(name);
    try list.append(0x00);
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, v, .little);
    try list.appendSlice(&b);
}

fn bsonAppendInt64(list: *std.array_list.Managed(u8), name: []const u8, v: i64) !void {
    try list.append(0x12);
    try list.appendSlice(name);
    try list.append(0x00);
    var b: [8]u8 = undefined;
    std.mem.writeInt(i64, &b, v, .little);
    try list.appendSlice(&b);
}

fn bsonAppendDouble(list: *std.array_list.Managed(u8), name: []const u8, v: f64) !void {
    try list.append(0x01);
    try list.appendSlice(name);
    try list.append(0x00);
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(v), .little);
    try list.appendSlice(&b);
}

fn bsonAppendBool(list: *std.array_list.Managed(u8), name: []const u8, v: bool) !void {
    try list.append(0x08);
    try list.appendSlice(name);
    try list.append(0x00);
    try list.append(if (v) 0x01 else 0x00);
}

fn bsonAppendNull(list: *std.array_list.Managed(u8), name: []const u8) !void {
    try list.append(0x0A);
    try list.appendSlice(name);
    try list.append(0x00);
}

fn bsonAppendString(list: *std.array_list.Managed(u8), name: []const u8, v: []const u8) !void {
    try list.append(0x02);
    try list.appendSlice(name);
    try list.append(0x00);
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, @intCast(v.len + 1), .little);
    try list.appendSlice(&b);
    try list.appendSlice(v);
    try list.append(0x00);
}

fn bsonAppendBinary(list: *std.array_list.Managed(u8), name: []const u8, subtype: u8, data: []const u8) !void {
    try list.append(0x05);
    try list.appendSlice(name);
    try list.append(0x00);
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, @intCast(data.len), .little);
    try list.appendSlice(&b);
    try list.append(subtype);
    try list.appendSlice(data);
}

fn bsonAppendDocument(list: *std.array_list.Managed(u8), name: []const u8, doc: []const u8) !void {
    try list.append(0x03);
    try list.appendSlice(name);
    try list.append(0x00);
    try list.appendSlice(doc);
}

fn bsonAppendArray(list: *std.array_list.Managed(u8), name: []const u8, doc: []const u8) !void {
    try list.append(0x04);
    try list.appendSlice(name);
    try list.append(0x00);
    try list.appendSlice(doc);
}

// ===================== JSON -> BSON =====================

fn jsonToBson(alloc: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();
    try appendJsonValue(&list, alloc, parsed.value);
    return try list.toOwnedSlice();
}

const BsonJsonError = error{
    MongoJsonUnsupported,
    MongoJsonNumber,
    MongoJsonNotDocument,
    MongoInvalidHex,
    MongoBsonUnsupported,
    NoSpaceLeft,
    OutOfMemory,
};

fn appendJsonValue(list: *std.array_list.Managed(u8), alloc: std.mem.Allocator, val: std.json.Value) BsonJsonError!void {
    try bsonStart(list);
    switch (val) {
        .object => |obj| {
            for (obj.keys(), obj.values()) |k, v| {
                try appendJsonField(list, alloc, k, v);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const key = try std.fmt.allocPrint(alloc, "{d}", .{i});
                defer alloc.free(key);
                try appendJsonField(list, alloc, key, item);
            }
        },
        else => return error.MongoJsonNotDocument,
    }
    try bsonFinish(list);
}

fn appendJsonField(list: *std.array_list.Managed(u8), alloc: std.mem.Allocator, name: []const u8, val: std.json.Value) BsonJsonError!void {
    switch (val) {
        .integer => |n| {
            if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) {
                try bsonAppendInt32(list, name, @intCast(n));
            } else {
                try bsonAppendInt64(list, name, n);
            }
        },
        .float => |f| try bsonAppendDouble(list, name, f),
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |n| {
                if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) {
                    try bsonAppendInt32(list, name, @intCast(n));
                } else {
                    try bsonAppendInt64(list, name, n);
                }
            } else |_| {
                const f = std.fmt.parseFloat(f64, s) catch return error.MongoJsonNumber;
                try bsonAppendDouble(list, name, f);
            }
        },
        .string => |s| try bsonAppendString(list, name, s),
        .bool => |b| try bsonAppendBool(list, name, b),
        .null => try bsonAppendNull(list, name),
        .object => |obj| {
            // Special forms: {"$oid":"hex"} -> ObjectId
            if (obj.get("$oid")) |oid_val| {
                if (oid_val == .string) {
                    const bytes = try hexDecode(alloc, oid_val.string);
                    defer alloc.free(bytes);
                    try list.append(0x07);
                    try list.appendSlice(name);
                    try list.append(0x00);
                    try list.appendSlice(bytes);
                    return;
                }
            }
            var sub = std.array_list.Managed(u8).init(alloc);
            defer sub.deinit();
            const sub_val: std.json.Value = .{ .object = obj };
            try appendJsonValue(&sub, alloc, sub_val);
            try bsonAppendDocument(list, name, sub.items);
        },
        .array => |arr| {
            var sub = std.array_list.Managed(u8).init(alloc);
            defer sub.deinit();
            try appendJsonValue(&sub, alloc, .{ .array = arr });
            try bsonAppendArray(list, name, sub.items);
        },
    }
}

fn hexDecode(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.MongoInvalidHex;
    const out = try alloc.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const hi = hexVal(hex[i]) orelse return error.MongoInvalidHex;
        const lo = hexVal(hex[i + 1]) orelse return error.MongoInvalidHex;
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ===================== BSON -> JSON =====================

const BsonValue = union(enum) {
    double: f64,
    string: []const u8,
    document: []const u8,
    array: []const u8,
    binary: []const u8,
    object_id: []const u8,
    boolean: bool,
    datetime: i64,
    null: void,
    int32: i32,
    int64: i64,
};

/// Find a top-level field by name in a BSON document. Returned slices point
/// into `doc`; the caller must use them before `doc` is freed.
fn bsonFind(doc: []const u8, name: []const u8) ?BsonValue {
    if (doc.len < 5) return null;
    var pos: usize = 4; // skip length prefix
    while (pos < doc.len) {
        const t = doc[pos];
        if (t == 0x00) break;
        pos += 1;
        // name (cstring)
        const name_start = pos;
        while (pos < doc.len and doc[pos] != 0) : (pos += 1) {}
        const field_name = doc[name_start..pos];
        pos += 1; // skip nul
        const res = readBsonValueAt(doc, &pos, t) catch return null;
        if (std.mem.eql(u8, field_name, name)) return res;
    }
    return null;
}

fn readBsonValueAt(doc: []const u8, pos: *usize, t: u8) !BsonValue {
    switch (t) {
        0x01 => { // double
            const v = std.mem.readInt(u64, doc[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .double = @bitCast(v) };
        },
        0x02 => { // string
            const len = std.mem.readInt(i32, doc[pos.*..][0..4], .little);
            pos.* += 4;
            const s = doc[pos.* .. pos.* + @as(usize, @intCast(len - 1))];
            pos.* += @as(usize, @intCast(len));
            return .{ .string = s };
        },
        0x03 => { // document
            const len = std.mem.readInt(i32, doc[pos.*..][0..4], .little);
            const d = doc[pos.* .. pos.* + @as(usize, @intCast(len))];
            pos.* += @as(usize, @intCast(len));
            return .{ .document = d };
        },
        0x04 => { // array (encoded as document)
            const len = std.mem.readInt(i32, doc[pos.*..][0..4], .little);
            const d = doc[pos.* .. pos.* + @as(usize, @intCast(len))];
            pos.* += @as(usize, @intCast(len));
            return .{ .array = d };
        },
        0x05 => { // binary
            const len = std.mem.readInt(i32, doc[pos.*..][0..4], .little);
            pos.* += 4;
            pos.* += 1; // subtype
            const b = doc[pos.* .. pos.* + @as(usize, @intCast(len))];
            pos.* += @as(usize, @intCast(len));
            return .{ .binary = b };
        },
        0x07 => { // ObjectId
            const b = doc[pos.* .. pos.* + 12];
            pos.* += 12;
            return .{ .object_id = b };
        },
        0x08 => { // bool
            const b = doc[pos.*] != 0;
            pos.* += 1;
            return .{ .boolean = b };
        },
        0x09 => { // datetime
            const v = std.mem.readInt(i64, doc[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .datetime = v };
        },
        0x0A => return .{ .null = {} },
        0x10 => { // int32
            const v = std.mem.readInt(i32, doc[pos.*..][0..4], .little);
            pos.* += 4;
            return .{ .int32 = v };
        },
        0x12 => { // int64
            const v = std.mem.readInt(i64, doc[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .int64 = v };
        },
        else => return error.MongoBsonUnsupported,
    }
}

fn bsonToJson(alloc: std.mem.Allocator, doc: []const u8) BsonJsonError![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    try bsonDocToJson(&list, alloc, doc, false);
    return try list.toOwnedSlice();
}

fn bsonDocToJson(list: *std.array_list.Managed(u8), alloc: std.mem.Allocator, doc: []const u8, is_array: bool) BsonJsonError!void {
    if (is_array) {
        try list.append('[');
    } else {
        try list.append('{');
    }
    if (doc.len < 5) {
        try list.append(if (is_array) ']' else '}');
        return;
    }
    var pos: usize = 4;
    var first = true;
    while (pos < doc.len) {
        const t = doc[pos];
        if (t == 0x00) break;
        pos += 1;
        const name_start = pos;
        while (pos < doc.len and doc[pos] != 0) : (pos += 1) {}
        const field_name = doc[name_start..pos];
        pos += 1;
        const val = readBsonValueAt(doc, &pos, t) catch break;

        if (!first) {
            try list.append(',');
        }
        first = false;

        if (!is_array) {
            try writeJsonString(list, field_name);
            try list.append(':');
        }
        try writeBsonValueJson(list, alloc, val);
    }
    try list.append(if (is_array) ']' else '}');
}

fn writeBsonValueJson(list: *std.array_list.Managed(u8), alloc: std.mem.Allocator, val: BsonValue) BsonJsonError!void {
    switch (val) {
        .double => |v| {
            var buf2: [48]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf2, "{d}", .{v});
            try list.appendSlice(s);
        },
        .string => |s| try writeJsonString(list, s),
        .document => |d| try bsonDocToJson(list, alloc, d, false),
        .array => |a| try bsonDocToJson(list, alloc, a, true),
        .binary => |b| {
            const b64 = try b64Encode(alloc, b);
            defer alloc.free(b64);
            try list.append('"');
            try list.appendSlice(b64);
            try list.append('"');
        },
        .object_id => |b| {
            var hex: [24]u8 = undefined;
            const h = "0123456789abcdef";
            for (b, 0..) |byte, i| {
                hex[2 * i] = h[(byte >> 4) & 0xf];
                hex[2 * i + 1] = h[byte & 0xf];
            }
            try list.appendSlice("{\"$oid\":\"");
            try list.appendSlice(&hex);
            try list.appendSlice("\"}");
        },
        .boolean => |b| try list.append(if (b) 't' else 'f'),
        .datetime => |v| {
            var buf2: [48]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf2, "{d}", .{v});
            try list.appendSlice(s);
        },
        .null => try list.appendSlice("null"),
        .int32 => |v| {
            var buf2: [48]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf2, "{d}", .{v});
            try list.appendSlice(s);
        },
        .int64 => |v| {
            var buf2: [48]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf2, "{d}", .{v});
            try list.appendSlice(s);
        },
    }
}

fn writeJsonString(list: *std.array_list.Managed(u8), s: []const u8) BsonJsonError!void {
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

// ===================== SCRAM command builders =====================

fn buildSaslStart(alloc: std.mem.Allocator, client_first: []const u8, auth_source: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    var opt = std.array_list.Managed(u8).init(alloc);
    defer opt.deinit();

    try bsonStart(&opt);
    try bsonAppendBool(&opt, "skipEmptyExchange", true);
    try bsonFinish(&opt);

    try bsonStart(&list);
    try bsonAppendInt32(&list, "saslStart", 1);
    try bsonAppendString(&list, "mechanism", "SCRAM-SHA-256");
    try bsonAppendDocument(&list, "options", opt.items);
    try bsonAppendBinary(&list, "payload", 0, client_first);
    try bsonAppendString(&list, "$db", auth_source);
    try bsonFinish(&list);
    return try list.toOwnedSlice();
}

fn buildSaslContinue(alloc: std.mem.Allocator, conversation_id: i32, client_final: []const u8, auth_source: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    try bsonStart(&list);
    try bsonAppendInt32(&list, "saslContinue", 1);
    try bsonAppendInt32(&list, "conversationId", conversation_id);
    try bsonAppendBinary(&list, "payload", 0, client_final);
    try bsonAppendString(&list, "$db", auth_source);
    try bsonFinish(&list);
    return try list.toOwnedSlice();
}

// ===================== Tests =====================

test "mongodb bson<->json roundtrip and field lookup" {
    const a = std.testing.allocator;
    const bson = try jsonToBson(a, "{\"a\":1,\"big\":9223372036854775807,\"b\":\"hi\",\"flag\":true,\"arr\":[1,2,3],\"n\":null}");
    defer a.free(bson);

    const a_v = bsonFind(bson, "a") orelse return error.TestExpected;
    try std.testing.expect(a_v == .int32 and a_v.int32 == 1);
    const big_v = bsonFind(bson, "big") orelse return error.TestExpected;
    try std.testing.expect(big_v == .int64 and big_v.int64 == 9223372036854775807);
    const b_v = bsonFind(bson, "b") orelse return error.TestExpected;
    try std.testing.expect(b_v == .string and std.mem.eql(u8, b_v.string, "hi"));
    const flag_v = bsonFind(bson, "flag") orelse return error.TestExpected;
    try std.testing.expect(flag_v == .boolean and flag_v.boolean);
    const n_v = bsonFind(bson, "n") orelse return error.TestExpected;
    try std.testing.expect(n_v == .null);

    const json = try bsonToJson(a, bson);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arr\":[1,2,3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"big\":9223372036854775807") != null);
}

test "mongodb $oid encodes to ObjectId" {
    const a = std.testing.allocator;
    const bson = try jsonToBson(a, "{\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"}}");
    defer a.free(bson);
    const id = bsonFind(bson, "_id") orelse return error.TestExpected;
    try std.testing.expect(id == .object_id and id.object_id.len == 12);
}

test "mongodb saslStart command is well-formed BSON" {
    const a = std.testing.allocator;
    const cmd = try buildSaslStart(a, "n,,n=user,r=abc", "admin");
    defer a.free(cmd);
    // length prefix must match the buffer
    const len = std.mem.readInt(u32, cmd[0..4], .little);
    try std.testing.expect(len == cmd.len);
    try std.testing.expect(bsonFind(cmd, "saslStart") != null);
    try std.testing.expect(bsonFind(cmd, "mechanism") != null);
    try std.testing.expect(bsonFind(cmd, "payload") != null);
    try std.testing.expect(bsonFind(cmd, "$db") != null);
}
