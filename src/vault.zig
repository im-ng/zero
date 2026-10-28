const std = @import("std");
const root = @import("zero.zig");
const zul = @import("zul");

/// HashiCorp Vault secret injection for `zero`.
///
/// When `VAULT_ADDR` is set, `load` authenticates (via `VAULT_TOKEN`, or an
/// AppRole login with `VAULT_ROLE_ID` + `VAULT_SECRET_ID`) and fetches every
/// comma-separated `VAULT_SECRETS_PATH`, merging the returned key/value pairs
/// into the process environment. Subsequent datasource wiring (`DB_*`, `REDIS_*`,
/// ...) then reads credentials that never lived in a file or image. Secret
/// values are never logged.
///
/// KV v2 nests secrets under `mount/data/path`; KV v1 under `mount/path`. The
/// `vault kv` CLI inserts the `data/` segment automatically, so we accept either
/// form: a `404` on the given path is retried once with `data/` inserted.
pub fn load(allocator: std.mem.Allocator, io: std.Io, config: *root.config, log: *root.logger) !void {
    var addr = std.mem.trim(u8, config.getOrDefault("VAULT_ADDR", ""), " \t\r\n");
    if (addr.len > 0 and std.mem.endsWith(u8, addr, "/")) {
        addr = addr[0 .. addr.len - 1];
    }
    if (addr.len == 0) return;

    const token_raw = try resolveToken(allocator, io, config, addr);
    const token = std.mem.trim(u8, token_raw, " \t\r\n");
    if (token.len == 0) {
        log.err("vault: VAULT_ADDR set but no token available (set VAULT_TOKEN or VAULT_ROLE_ID+VAULT_SECRET_ID)");
        return;
    }

    const paths = config.getOrDefault("VAULT_SECRETS_PATH", "");
    if (paths.len == 0) {
        log.warn("vault: VAULT_ADDR set but VAULT_SECRETS_PATH empty; nothing to fetch");
        return;
    }

    var it = std.mem.splitScalar(u8, paths, ',');
    while (it.next()) |raw| {
        const path = std.mem.trim(u8, raw, " ");
        if (path.len == 0) continue;
        fetchAndMerge(allocator, io, config, log, addr, token, path) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "vault: failed to load secret path '{s}': {s}", .{ path, @errorName(err) }) catch "vault: failed to load secret path";
            log.err(msg);
            return err;
        };
    }

    var buf: [256]u8 = undefined;
    const loaded = std.fmt.bufPrint(&buf, "vault: loaded secrets from {s}", .{addr}) catch "vault: loaded secrets from vault";
    log.info(loaded);
}

fn resolveToken(allocator: std.mem.Allocator, io: std.Io, config: *root.config, addr: []const u8) ![]const u8 {
    const explicit = config.getOrDefault("VAULT_TOKEN", "");
    if (explicit.len > 0) return explicit;

    const role_id = config.getOrDefault("VAULT_ROLE_ID", "");
    const secret_id = config.getOrDefault("VAULT_SECRET_ID", "");
    if (role_id.len == 0 or secret_id.len == 0) return "";

    return appRoleLogin(allocator, io, addr, role_id, secret_id);
}

fn appRoleLogin(allocator: std.mem.Allocator, io: std.Io, addr: []const u8, role_id: []const u8, secret_id: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/auth/approle/login", .{addr});
    defer allocator.free(url);

    var client = zul.http.Client.init(io, allocator);
    defer client.deinit();

    var req = try client.allocRequest(allocator, url);
    defer req.deinit();
    req.method = .POST;

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"role_id\":\"{s}\",\"secret_id\":\"{s}\"}}",
        .{ role_id, secret_id },
    );
    defer allocator.free(body);
    req.body(body);

    var res = try req.getResponse(.{});
    if (res.status != 200) {
        return error.VaultLoginFailed;
    }

    var sb = try res.allocBody(allocator, .{ .max_size = 1 << 20 });
    defer sb.deinit();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        sb.string(),
        .{ .ignore_unknown_fields = true },
    ) catch return error.VaultLoginFailed;
    defer parsed.deinit();

    const auth = parsed.value.object.get("auth") orelse return error.VaultLoginFailed;
    if (auth != .object) {
        return error.VaultLoginFailed;
    }

    const token_v = auth.object.get("client_token") orelse return error.VaultLoginFailed;
    if (token_v != .string) {
        return error.VaultLoginFailed;
    }

    return allocator.dupe(u8, token_v.string);
}

fn fetchAndMerge(allocator: std.mem.Allocator, io: std.Io, config: *root.config, log: *root.logger, addr: []const u8, token: []const u8, path: []const u8) !void {
    fetchOne(allocator, io, config, log, addr, token, path) catch |err| {
        // KV v2 convenience: if the literal path 404s, retry once with the
        // `data/` segment inserted (matching `vault kv` CLI behaviour).
        if (err == error.VaultNotFound and std.mem.indexOf(u8, path, "data/") == null) {
            const v2 = try insertDataSegment(allocator, path);
            defer allocator.free(v2);
            fetchOne(allocator, io, config, log, addr, token, v2) catch {
                return error.VaultFetchFailed;
            };
            return;
        }
        return err;
    };
}

/// `mount/zero/db` -> `mount/data/zero/db` (insert `data/` after the first `/`).
fn insertDataSegment(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const idx = std.mem.indexOfScalar(u8, path, '/') orelse return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}data/{s}", .{ path[0 .. idx + 1], path[idx + 1 ..] });
}

fn fetchOne(allocator: std.mem.Allocator, io: std.Io, config: *root.config, log: *root.logger, addr: []const u8, token: []const u8, path: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/{s}", .{ addr, path });
    defer allocator.free(url);

    var client = zul.http.Client.init(io, allocator);
    defer client.deinit();
    var req = try client.allocRequest(allocator, url);
    defer req.deinit();
    req.method = .GET;
    req.header("X-Vault-Token", token) catch {};

    var res = try req.getResponse(.{});
    var sb = try res.allocBody(allocator, .{ .max_size = 1 << 20 });
    defer sb.deinit();

    if (res.status == 404) {
        // Let the caller retry with the KV v2 `data/` segment, or surface as a
        // miss if the path already contained one.
        return error.VaultNotFound;
    }
    if (res.status != 200) {
        const body = sb.string();
        const n = if (body.len > 240) 240 else body.len;
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "vault: GET {s} -> HTTP {d}: {s}", .{ url, res.status, body[0..n] }) catch "vault: secret fetch returned non-200";
        log.err(msg);
        return error.VaultFetchFailed;
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        sb.string(),
        .{ .ignore_unknown_fields = true },
    ) catch {
        log.err("vault: failed to parse secret JSON response");
        return error.VaultFetchFailed;
    };
    defer parsed.deinit();

    const secret_obj = extractSecretObject(parsed.value) orelse {
        log.err("vault: secret response missing a 'data' object");
        return error.VaultFetchFailed;
    };
    if (secret_obj != .object) {
        log.err("vault: secret 'data' is not an object");
        return error.VaultFetchFailed;
    }

    var obj_it = secret_obj.object.iterator();
    // Merge each secret key/value into the process-global environ map, exactly
    // like dotenv's .env injection. Duplicate with the map's own allocator so the
    // entries live for the process lifetime and are not tracked by the app's
    // DebugAllocator (the global environ map is never freed by design, matching
    // dotenv). Vault runs before datasources are wired, so these override any
    // .env value already present for the same key.
    while (obj_it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        const env_alloc = config.environments.allocator;
        const key = try env_alloc.dupe(u8, kv.key_ptr.*);
        const value = try env_alloc.dupe(u8, kv.value_ptr.*.string);
        try config.environments.put(key, value);
    }

    var buf: [256]u8 = undefined;
    const merged = std.fmt.bufPrint(&buf, "vault: merged secret path '{s}'", .{path}) catch "vault: merged secret path";
    log.debug(merged);
}

/// KV v2 nests secrets under `data.data`; KV v1 uses `data` directly. Return the
/// object that actually holds the secret key/value pairs.
fn extractSecretObject(root_v: std.json.Value) ?std.json.Value {
    const data = root_v.object.get("data") orelse return null;
    if (data != .object) return null;
    if (data.object.get("data")) |inner| {
        if (inner == .object) return inner;
    }
    return data;
}
