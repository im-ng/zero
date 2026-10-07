const std = @import("std");
const root = @import("../zero.zig");
const zul = root.zul;
const utils = root.utils;
const constants = root.constants;
const sigv4 = @import("../aws/sigv4.zig");

/// S3-compatible object store (MinIO / R2 / Spaces / B2 / AWS S3).
///
/// Requests are signed with AWS Signature Version 4 over the existing `zul`
/// HTTP client. Object keys map directly to S3 keys under `bucket`:
/// `create(ctx, "avatars/1.png", ...)` -> `PUT /<bucket>/avatars/1.png`.
pub const FileStoreS3 = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    host: []const u8,
    region: []const u8,
    bucket: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    max_bytes: usize = constants.DEFAULT_FILESTORE_MAX_BYTES_S3,

    /// A signed (name, value) header participating in the SigV4 signature.
    pub const Header = sigv4.Header;

    /// Builds an S3 store from env config:
    ///   S3_ENDPOINT (optional; default https://s3.<region>.amazonaws.com)
    ///   S3_REGION   (default us-east-1)
    ///   S3_BUCKET   (required)
    ///   S3_ACCESS_KEY / S3_SECRET_KEY (required)
    pub fn open(allocator: std.mem.Allocator, container: *root.container) !*FileStoreS3 {
        const region = container.config.getOrDefault("S3_REGION", "us-east-1");
        const bucket = container.config.getOrDefault("S3_BUCKET", "");
        const access_key = container.config.getOrDefault("S3_ACCESS_KEY", "");
        const secret_key = container.config.getOrDefault("S3_SECRET_KEY", "");
        if (bucket.len == 0) return error.S3BucketRequired;
        if (access_key.len == 0 or secret_key.len == 0) return error.S3CredentialsRequired;

        const endpoint_cfg = container.config.getOrDefault("S3_ENDPOINT", "");
        const endpoint = if (endpoint_cfg.len > 0)
            try allocator.dupe(u8, endpoint_cfg)
        else
            try std.fmt.allocPrint(allocator, "https://s3.{s}.amazonaws.com", .{region});

        const self = try allocator.create(FileStoreS3);
        self.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .host = try sigv4.hostOf(allocator, endpoint),
            .region = try allocator.dupe(u8, region),
            .bucket = try allocator.dupe(u8, bucket),
            .access_key = try allocator.dupe(u8, access_key),
            .secret_key = try allocator.dupe(u8, secret_key),
        };
        return self;
    }

    /// Builds a Supabase Storage store reusing the S3-compatible transport (the
    /// Supabase Storage API exposes an S3-compatible surface at
    /// `https://<project>.supabase.co/storage/v1/s3`). Reads:
    ///   SUPABASE_STORAGE_PROJECT   (project ref; host becomes db.<ref>.supabase.co)
    ///   SUPABASE_STORAGE_ENDPOINT  (optional; overrides the default project host)
    ///   SUPABASE_STORAGE_REGION    (default us-east-1, required by SigV4 scope)
    ///   SUPABASE_STORAGE_BUCKET    (required)
    ///   SUPABASE_STORAGE_ACCESS_KEY / SUPABASE_STORAGE_SECRET_KEY (required)
    ///
    /// The S3 access key + secret are the "S3 Access Keys" shown in the Supabase
    /// Storage settings panel (not the anon/service-role JWTs).
    pub fn openSupabase(allocator: std.mem.Allocator, container: *root.container) !*FileStoreS3 {
        const bucket = container.config.getOrDefault("SUPABASE_STORAGE_BUCKET", "");
        const access_key = container.config.getOrDefault("SUPABASE_STORAGE_ACCESS_KEY", "");
        const secret_key = container.config.getOrDefault("SUPABASE_STORAGE_SECRET_KEY", "");
        if (bucket.len == 0) return error.S3BucketRequired;
        if (access_key.len == 0 or secret_key.len == 0) return error.S3CredentialsRequired;

        const region = container.config.getOrDefault("SUPABASE_STORAGE_REGION", "us-east-1");

        const endpoint_cfg = container.config.getOrDefault("SUPABASE_STORAGE_ENDPOINT", "");
        const endpoint = if (endpoint_cfg.len > 0)
            try allocator.dupe(u8, endpoint_cfg)
        else blk: {
            const project = container.config.getOrDefault("SUPABASE_STORAGE_PROJECT", "");
            if (project.len == 0) return error.SupabaseStorageProjectRequired;
            break :blk try std.fmt.allocPrint(
                allocator,
                "https://{s}.supabase.co/storage/v1/s3",
                .{project},
            );
        };

        const self = try allocator.create(FileStoreS3);
        self.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .host = try sigv4.hostOf(allocator, endpoint),
            .region = try allocator.dupe(u8, region),
            .bucket = try allocator.dupe(u8, bucket),
            .access_key = try allocator.dupe(u8, access_key),
            .secret_key = try allocator.dupe(u8, secret_key),
        };
        return self;
    }

    /// Frees the S3 client and all owned config strings allocated in `open`.
    pub fn deinit(self: *FileStoreS3) void {
        const allocator = self.allocator;
        allocator.free(self.endpoint);
        allocator.free(self.host);
        allocator.free(self.region);
        allocator.free(self.bucket);
        allocator.free(self.access_key);
        allocator.free(self.secret_key);
        allocator.destroy(self);
    }

    fn objectUrl(self: *FileStoreS3, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const enc = try sigv4.encodePath(allocator, key);
        defer allocator.free(enc);
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ self.endpoint, self.bucket, enc });
    }

    fn canonicalUri(self: *FileStoreS3, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const enc = try sigv4.encodePath(allocator, key);
        defer allocator.free(enc);
        return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.bucket, enc });
    }

    fn authHeaders(
        self: *FileStoreS3,
        allocator: std.mem.Allocator,
        method: []const u8,
        uri: []const u8,
        payload_hash: []const u8,
    ) !struct { authorization: []const u8, amz_date: []const u8, content_sha256: []const u8 } {
        const amz_date = try sigv4.amzDate(allocator);
        const signed = [_]Header{
            .{ .name = "host", .value = self.host },
            .{ .name = "x-amz-content-sha256", .value = payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };
        const authorization = try sigv4.signAuthorization(
            allocator,
            method,
            uri,
            "",
            self.region,
            "s3",
            self.access_key,
            self.secret_key,
            payload_hash,
            amz_date,
            &signed,
        );
        return .{ .authorization = authorization, .amz_date = amz_date, .content_sha256 = try allocator.dupe(u8, payload_hash) };
    }

    pub fn create(self: *FileStoreS3, ctx: *root.Context, key: []const u8, data: []const u8) !void {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sigv4.sha256Hex(data));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "PUT", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var client = zul.http.Client.init(ctx.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .PUT;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);
        req.body(data);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3PutFailed;
    }

    pub fn get(self: *FileStoreS3, ctx: *root.Context, key: []const u8) !?[]const u8 {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sigv4.sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "GET", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var client = zul.http.Client.init(ctx.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

        var res = try req.getResponse(.{});
        if (res.status == 404) return null;
        if (res.status < 200 or res.status > 299) return error.S3GetFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        const slice = try ctx.allocator.dupe(u8, sb.string());
        sb.deinit();
        return slice;
    }

    pub fn delete(self: *FileStoreS3, ctx: *root.Context, key: []const u8) !void {
        const url = try self.objectUrl(ctx.allocator, key);
        defer ctx.allocator.free(url);
        const uri = try self.canonicalUri(ctx.allocator, key);
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sigv4.sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "DELETE", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var client = zul.http.Client.init(ctx.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .DELETE;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

        const res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3DeleteFailed;
    }

    pub fn list(self: *FileStoreS3, ctx: *root.Context, prefix: []const u8) ![][]const u8 {
        const enc_prefix = try sigv4.encodePath(ctx.allocator, prefix);
        defer ctx.allocator.free(enc_prefix);
        const url = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}?list-type=2&prefix={s}", .{ self.endpoint, self.bucket, enc_prefix });
        defer ctx.allocator.free(url);
        const uri = try std.fmt.allocPrint(ctx.allocator, "/{s}/?list-type=2&prefix={s}", .{ self.bucket, enc_prefix });
        defer ctx.allocator.free(uri);

        const payload_hash = try ctx.allocator.dupe(u8, &sigv4.sha256Hex(""));
        defer ctx.allocator.free(payload_hash);

        const h = try self.authHeaders(ctx.allocator, "GET", uri, payload_hash);
        defer {
            ctx.allocator.free(h.authorization);
            ctx.allocator.free(h.amz_date);
            ctx.allocator.free(h.content_sha256);
        }

        var client = zul.http.Client.init(ctx.io, ctx.allocator);
        defer client.deinit();
        var req = try client.allocRequest(ctx.allocator, url);
        defer req.deinit();
        req.method = .GET;
        try req.header("x-amz-date", h.amz_date);
        try req.header("x-amz-content-sha256", h.content_sha256);
        try req.header("authorization", h.authorization);

        var res = try req.getResponse(.{});
        if (res.status < 200 or res.status > 299) return error.S3ListFailed;

        var sb = try res.allocBody(ctx.allocator, .{ .max_size = self.max_bytes });
        const body = try ctx.allocator.dupe(u8, sb.string());
        defer {
            sb.deinit();
            ctx.allocator.free(body);
        }

        // S3 list returns an XML <Contents> element per object; pull <Key> values.
        var out = std.array_list.Managed([]const u8).init(ctx.allocator);
        errdefer {
            for (out.items) |k| {
                ctx.allocator.free(k);
            }
            out.deinit();
        }
        var i: usize = 0;
        while (i < body.len) {
            const start = std.mem.indexOfPos(u8, body, i, "<Key>") orelse break;
            const after = start + "<Key>".len;
            const end = std.mem.indexOfPos(u8, body, after, "</Key>") orelse break;
            try out.append(try ctx.allocator.dupe(u8, body[after..end]));
            i = end + "</Key>".len;
        }
        return out.toOwnedSlice();
    }
};

