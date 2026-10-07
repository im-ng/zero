const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;
const constants = root.constants;

/// GCS (Google Cloud Storage) object store over the JSON / resumable-upload
/// REST API, authenticated with an OAuth2 bearer token.
///
/// The token is obtained via the OAuth2 client-credentials grant against
/// `GCS_TOKEN_URL` (default `https://oauth2.googleapis.com/token`) using
/// `GCS_CLIENT_ID` / `GCS_CLIENT_SECRET` / `GCS_SCOPE`. When `GCS_ACCESS_TOKEN`
/// is set it is used directly (no fetch), which also covers token-injected
/// deployments (workload identity, sidecars). The downloaded object body is
/// returned in the response; keys map to GCS object names under `bucket`.
pub const FileStoreGCS = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    bucket: []const u8,
    project: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: []const u8,
    /// When non-empty, used verbatim as the bearer token (no token fetch).
    access_token_override: []const u8,

    token: ?[]const u8 = null,
    token_expires_at_ns: i128 = 0,

    max_bytes: usize = constants.DEFAULT_FILESTORE_MAX_BYTES_S3,

    /// Resolved parameters for `create`. `open` fills these from env.
    pub const Options = struct {
        endpoint: []const u8 = "https://storage.googleapis.com",
        bucket: []const u8,
        project: []const u8 = "",
        token_url: []const u8 = "https://oauth2.googleapis.com/token",
        client_id: []const u8 = "",
        client_secret: []const u8 = "",
        scope: []const u8 = "https://www.googleapis.com/auth/devstorage.full_control",
        access_token_override: []const u8 = "",
    };

    /// Direct constructor used by tests and callers that already hold the
    /// resolved parameters. `open` reads the same keys from env and calls this.
    pub fn init(allocator: std.mem.Allocator, opts: Options) !*FileStoreGCS {
        if (opts.bucket.len == 0) return error.GcsBucketRequired;

        const self = try allocator.create(FileStoreGCS);
        self.* = .{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, opts.endpoint),
            .bucket = try allocator.dupe(u8, opts.bucket),
            .project = try allocator.dupe(u8, opts.project),
            .token_url = try allocator.dupe(u8, opts.token_url),
            .client_id = try allocator.dupe(u8, opts.client_id),
            .client_secret = try allocator.dupe(u8, opts.client_secret),
            .scope = try allocator.dupe(u8, opts.scope),
            .access_token_override = try allocator.dupe(u8, opts.access_token_override),
        };
        return self;
    }

    /// Builds a GCS store from env config:
    ///   GCS_BUCKET            (required)
    ///   GCS_ENDPOINT          (default https://storage.googleapis.com)
    ///   GCS_PROJECT           (optional; included for completeness)
    ///   GCS_TOKEN_URL         (default https://oauth2.googleapis.com/token)
    ///   GCS_CLIENT_ID / GCS_CLIENT_SECRET (optional; enable token fetch)
    ///   GCS_SCOPE             (default devstorage.full_control)
    ///   GCS_ACCESS_TOKEN      (optional; bypasses the token fetch)
    pub fn open(allocator: std.mem.Allocator, container: *root.container) !*FileStoreGCS {
        return init(allocator, .{
            .endpoint = container.config.getOrDefault("GCS_ENDPOINT", "https://storage.googleapis.com"),
            .bucket = container.config.getOrDefault("GCS_BUCKET", ""),
            .project = container.config.getOrDefault("GCS_PROJECT", ""),
            .token_url = container.config.getOrDefault("GCS_TOKEN_URL", "https://oauth2.googleapis.com/token"),
            .client_id = container.config.getOrDefault("GCS_CLIENT_ID", ""),
            .client_secret = container.config.getOrDefault("GCS_CLIENT_SECRET", ""),
            .scope = container.config.getOrDefault("GCS_SCOPE", "https://www.googleapis.com/auth/devstorage.full_control"),
            .access_token_override = container.config.getOrDefault("GCS_ACCESS_TOKEN", ""),
        });
    }

    /// Frees the GCS client and all owned config strings allocated in `open`.
    pub fn deinit(self: *FileStoreGCS) void {
        const allocator = self.allocator;
        allocator.free(self.endpoint);
        allocator.free(self.bucket);
        allocator.free(self.project);
        allocator.free(self.token_url);
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.scope);
        allocator.free(self.access_token_override);
        if (self.token) |t| {
            allocator.free(t);
        }
        allocator.destroy(self);
    }

    fn ensureToken(self: *FileStoreGCS) ![]const u8 {
        if (self.access_token_override.len > 0) {
            return self.access_token_override;
        }
        if (self.token) |t| {
            if (utils.nowMonotonic().nanoseconds < self.token_expires_at_ns) {
                return t;
            }
        }
        if (self.client_id.len == 0 or self.client_secret.len == 0) {
            return error.GcsTokenFetchFailed;
        }

        const tok = root.gcp_oauth.fetchToken(
            self.allocator,
            utils.io,
            self.token_url,
            self.client_id,
            self.client_secret,
            self.scope,
        ) catch return error.GcsTokenFetchFailed;

        if (self.token) |old| {
            self.allocator.free(old);
        }
        // 30s skew so we refresh before the token actually lapses.
        self.token_expires_at_ns = utils.nowMonotonic().nanoseconds + 3600 * 1_000_000_000 - 30_000_000_000;
        self.token = tok;
        return tok;
    }

    pub fn create(self: *FileStoreGCS, ctx: *root.Context, key: []const u8, data: []const u8) !void {
        const token = try self.ensureToken();
        const enc = try encodePath(ctx.allocator, key);
        defer ctx.allocator.free(enc);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/upload/storage/v1/b/{s}/o?uploadType=media&name={s}", .{ self.endpoint, self.bucket, enc });
        defer ctx.allocator.free(url);

        var client = zul.http.Client.init(utils.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .POST;
        try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token}));
        try req.header("content-type", "application/octet-stream");
        req.body(data);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.GcsPutFailed;
    }

    pub fn get(self: *FileStoreGCS, ctx: *root.Context, key: []const u8) !?[]const u8 {
        const token = try self.ensureToken();
        const enc = try encodePath(ctx.allocator, key);
        defer ctx.allocator.free(enc);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/storage/v1/b/{s}/o/{s}?alt=media", .{ self.endpoint, self.bucket, enc });
        defer ctx.allocator.free(url);

        var client = zul.http.Client.init(utils.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token}));

        var res = try req.getResponse(.{});
        if (res.status == 404) return null;
        if (res.status < 200 or res.status > 299) return error.GcsGetFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        const slice = try ctx.allocator.dupe(u8, sb.string());
        sb.deinit();
        return slice;
    }

    pub fn delete(self: *FileStoreGCS, ctx: *root.Context, key: []const u8) !void {
        const token = try self.ensureToken();
        const enc = try encodePath(ctx.allocator, key);
        defer ctx.allocator.free(enc);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/storage/v1/b/{s}/o/{s}", .{ self.endpoint, self.bucket, enc });
        defer ctx.allocator.free(url);

        var client = zul.http.Client.init(utils.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .DELETE;
        try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token}));

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.GcsDeleteFailed;
    }

    pub fn list(self: *FileStoreGCS, ctx: *root.Context, prefix: []const u8) ![][]const u8 {
        const token = try self.ensureToken();
        const enc_prefix = try encodePath(ctx.allocator, prefix);
        defer ctx.allocator.free(enc_prefix);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/storage/v1/b/{s}/o?prefix={s}", .{ self.endpoint, self.bucket, enc_prefix });
        defer ctx.allocator.free(url);

        var client = zul.http.Client.init(utils.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("authorization", try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token}));

        var res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.GcsListFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        defer sb.deinit();

        var out = std.array_list.Managed([]const u8).init(ctx.allocator);
        errdefer {
            for (out.items) |k| {
                ctx.allocator.free(k);
            }
            out.deinit();
        }

        const parsed = std.json.parseFromSlice(ListResp, ctx.allocator, sb.string(), .{}) catch {
            return out.toOwnedSlice();
        };
        defer parsed.deinit();
        if (parsed.value.items) |items| {
            for (items) |item| {
                try out.append(try ctx.allocator.dupe(u8, item.name));
            }
        }
        return out.toOwnedSlice();
    }

    const TokenResp = struct {
        access_token: []const u8,
        expires_in: u64 = 3600,
    };

    const ListResp = struct {
        items: ?[]const GcsObject = null,
    };

    const GcsObject = struct {
        name: []const u8,
    };
};

/// URI-encodes a key for use in a URL path, preserving `/` and the unreserved set.
fn encodePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (path) |c| {
        const safe = c == '/' or
            (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(c);
            continue;
        }
        var hex: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{X}", .{c}) catch unreachable;
        try out.append('%');
        try out.appendSlice(&hex);
    }
    return out.toOwnedSlice();
}
